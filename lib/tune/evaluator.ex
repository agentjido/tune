defmodule Tune.Evaluator do
  @moduledoc false

  alias Tune.Case
  alias Tune.Dataset
  alias Tune.Error
  alias Tune.Evaluation
  alias Tune.Observation
  alias Tune.Prediction
  alias Tune.Score
  alias Tune.Score.Selector
  alias Tune.Score.Summary

  @type state :: %{
          observations: [Observation.t()],
          budget: non_neg_integer() | nil,
          stop_reason: atom() | nil,
          expires_at: integer() | nil,
          dataset: {list(), [Case.t()]} | nil
        }

  @spec evaluate(Enumerable.t(), (Case.t() -> term()), [Score.t()], term(), map()) ::
          Evaluation.t()
  def evaluate(source, runner, scores, selector, limits) do
    expires_at = limits[:expires_at] || expiration(limits[:deadline])
    concurrency = Map.get(limits, :concurrency, 1)
    {:ok, supervisor} = Task.Supervisor.start_link()
    reason = stop_reason(expires_at, limits)

    state = %{
      observations: [],
      budget: Map.get(limits, :model_calls),
      stop_reason: reason,
      expires_at: expires_at,
      dataset:
        if(
          reason == nil and limits[:dataset_split] != nil and is_function(limits[:on_dataset], 3),
          do: {[], []}
        )
    }

    try do
      source = if state.stop_reason, do: [], else: source

      source
      |> Dataset.lookahead(case_limit(limits))
      |> Stream.with_index()
      |> Stream.chunk_every(concurrency)
      |> Enum.reduce_while(state, fn chunk, state ->
        reduce_chunk(chunk, state, supervisor, runner, scores, limits)
      end)
      |> mark_truncation(limits)
      |> report_dataset(limits)
      |> summarize(scores, selector, limits)
    after
      Supervisor.stop(supervisor)
    end
  end

  @spec stopped([Case.t()], [Score.t()], term(), map(), atom()) :: Evaluation.t()
  def stopped(cases, scores, selector, limits, reason) do
    state = %{
      observations: Enum.reverse(cases) |> Enum.map(&skipped(&1, reason)),
      stop_reason: reason
    }

    summarize(state, scores, selector, limits)
  end

  defp mark_truncation(%{stop_reason: nil} = state, %{source_truncated?: true}),
    do: %{state | stop_reason: :case_limit}

  defp mark_truncation(state, _limits), do: state

  defp case_limit(%{source_truncated?: _}), do: nil
  defp case_limit(limits), do: limits[:cases]

  defp reduce_chunk(entries, state, supervisor, runner, scores, limits) do
    {entries, limited?} = Dataset.split_chunk(entries, case_limit(limits))
    chunk = Enum.map(entries, fn {value, index} -> {Case.normalize(value, index), index} end)
    state = collect_dataset(state, entries, chunk)

    cond do
      chunk == [] ->
        {:halt, %{state | stop_reason: :case_limit}}

      reason = stop_reason(state.expires_at, limits) ->
        observations = Enum.map(chunk, fn {tune_case, _index} -> skipped(tune_case, reason) end)
        {:halt, append(%{state | stop_reason: reason}, observations)}

      true ->
        {admitted, skipped_cases} = admit(chunk, state.budget, limits[:row_calls])

        {observations, worker_stop} =
          run_chunk(admitted, supervisor, runner, scores, state, limits)

        observations =
          observations ++
            Enum.map(skipped_cases, fn {tune_case, _index} ->
              skipped(tune_case, :model_call_limit)
            end)

        state = account(append(state, observations), observations)
        notify_progress(limits[:on_progress], state, observations)

        stop_reason =
          cond do
            worker_stop -> worker_stop
            lost_accounting?(observations, state.budget) -> :lost_accounting
            Enum.any?(observations, &(&1.status == :interrupted)) -> :model_call_limit
            skipped_cases != [] -> :model_call_limit
            reason = stop_reason(state.expires_at, limits) -> reason
            limited? -> :case_limit
            true -> nil
          end

        state = if stop_reason, do: %{state | stop_reason: stop_reason}, else: state
        if stop_reason, do: {:halt, state}, else: {:cont, state}
    end
  end

  defp collect_dataset(%{dataset: nil} = state, _entries, _chunk), do: state

  defp collect_dataset(%{dataset: {source, effective}} = state, entries, chunk) do
    source = Enum.reduce(entries, source, fn {row, _index}, acc -> [row | acc] end)

    effective =
      Enum.reduce(chunk, effective, fn {tune_case, _index}, acc -> [tune_case | acc] end)

    %{state | dataset: {source, effective}}
  end

  defp report_dataset(%{dataset: {source, effective}} = state, limits) do
    Dataset.report(limits, limits.dataset_split, :source, Enum.reverse(source))
    Dataset.report(limits, limits.dataset_split, :effective, Enum.reverse(effective))
    state
  end

  defp report_dataset(state, _limits), do: state

  defp run_chunk(admitted, supervisor, runner, scores, state, limits) do
    tasks =
      Enum.map(admitted, fn {{tune_case, _index}, allowance} ->
        task =
          Task.Supervisor.async_nolink(supervisor, fn ->
            evaluate_case(tune_case, runner, scores, allowance)
          end)

        {task, tune_case, allowance}
      end)

    row_expires = expiration(Map.get(limits, :row_timeout, 120_000))

    {replies, reason} =
      await_tasks(Enum.map(tasks, &elem(&1, 0)), %{}, row_expires, state.expires_at, limits)

    observations =
      Enum.map(tasks, fn {task, tune_case, allowance} ->
        outcome = Map.get(replies, task.ref) || Task.shutdown(task, :brutal_kill)
        task_observation(outcome, tune_case, allowance, limits[:call_role] || :target)
      end)

    {observations, reason}
  end

  defp await_tasks([], replies, _row_expires, _expires_at, _limits), do: {replies, nil}

  defp await_tasks(tasks, replies, row_expires, expires_at, limits) do
    reason = stop_reason(expires_at, limits)
    timeout = min(remaining_ms(row_expires), remaining_ms(expires_at))

    if reason || timeout == 0 do
      {replies, reason}
    else
      interval = if limits[:cancel], do: min(20, timeout), else: timeout

      {pending, replies} =
        tasks
        |> Task.yield_many(interval)
        |> Enum.reduce({[], replies}, fn
          {task, nil}, {pending, acc} -> {[task | pending], acc}
          {task, reply}, {pending, acc} -> {pending, Map.put(acc, task.ref, reply)}
        end)

      await_tasks(pending, replies, row_expires, expires_at, limits)
    end
  end

  defp notify_progress(nil, _state, _observations), do: :ok

  defp notify_progress(callback, state, observations) do
    callback.(%{
      event: :rows_evaluated,
      rows: Enum.map(observations, &%{id: &1.id, status: &1.status}),
      model_calls_remaining: state.budget
    })
  end

  defp evaluate_case(%Case{} = tune_case, runner, scores, allowance) do
    tune_case = put_allowance(tune_case, allowance)

    case invoke(runner, tune_case) do
      {:score_prediction, %Prediction{} = prediction} ->
        score_case(tune_case, prediction.output, prediction, %{}, scores, allowance, false)

      {:ok, output, %Prediction{} = prediction, metadata} ->
        score_case(tune_case, output, prediction, metadata, scores, allowance, true)

      {:ok, output, nil, metadata} ->
        score_case(tune_case, output, nil, metadata, scores, allowance, true)

      {:error, error, prediction, metadata} ->
        %Observation{
          id: tune_case.id,
          status: interruption_status(error, allowance),
          eligible?: false,
          prediction: prediction,
          output: prediction && prediction.output,
          error: error,
          calls: calls(prediction),
          metadata: Map.put(metadata, :case, tune_case)
        }
    end
  rescue
    error -> failed(tune_case, error)
  catch
    kind, reason -> failed(tune_case, {kind, reason})
  end

  defp invoke(runner, tune_case) do
    case runner.(tune_case) do
      {:score_prediction, %Prediction{}} = result -> result
      {:ok, output, %Prediction{} = prediction} -> {:ok, output, prediction, %{}}
      {:ok, output, %Prediction{} = prediction, metadata} -> {:ok, output, prediction, metadata}
      {:ok, output, metadata} when is_map(metadata) -> {:ok, output, nil, metadata}
      {:ok, output} -> {:ok, output, nil, %{}}
      {:error, error, %Prediction{} = prediction} -> {:error, error, prediction, %{}}
      {:error, error} -> {:error, error, nil, %{}}
      output -> {:ok, output, nil, %{}}
    end
  end

  defp score_case(tune_case, output, prediction, metadata, scores, allowance, account_prediction?) do
    recorded_prediction = if account_prediction?, do: prediction
    initial_calls = calls(recorded_prediction)

    observation = %Observation{
      id: tune_case.id,
      output: output,
      prediction: recorded_prediction,
      calls: initial_calls,
      metadata: metadata |> Map.put(:case, tune_case) |> Map.put(:scores, %{})
    }

    Enum.reduce(scores, observation, fn score, observation ->
      left = remaining(allowance, total_calls(observation.calls))
      scored_case = put_allowance(tune_case, left)

      case Score.execute(score, scored_case, output, prediction) do
        {:ok, value, evidence} ->
          observation
          |> put_score_evidence(score.name, evidence)
          |> put_in([Access.key(:scores), score.name], value.score)
          |> put_in([Access.key(:feedback), score.name], value.feedback)

        {:error, error, evidence} ->
          status = interruption_status(error, allowance)
          status = if observation.status == :interrupted, do: :interrupted, else: status

          observation
          |> put_score_evidence(score.name, evidence)
          |> Map.put(:status, status)
          |> Map.update!(:error, &(&1 || error))
          |> put_in([Access.key(:score_errors), score.name], error)
      end
    end)
  end

  defp put_score_evidence(observation, name, evidence) do
    %{observation | calls: merge_counts(observation.calls, Map.get(evidence, :calls, %{}))}
    |> put_in([Access.key(:metadata), :scores, name], Map.delete(evidence, :calls))
  end

  defp summarize(state, scores, selector, limits) do
    observations =
      state.observations
      |> Enum.reverse()
      |> Enum.map(&put_selection(&1, scores, selector))

    total = length(observations)
    summaries = Map.new(scores, &{&1.name, summary(&1, observations, total)})
    complete? = state.stop_reason in [nil, :case_limit] and all_attempted?(observations)
    eligible? = complete? and total > 0 and Enum.all?(observations, & &1.eligible?)

    {usage, cost} = observations |> Stream.flat_map(&call_usage/1) |> Prediction.usage_totals()

    %Evaluation{
      observations: observations,
      summaries: summaries,
      selected_score: if(eligible?, do: selected_mean(observations, scores, selector)),
      eligible?: eligible?,
      complete?: complete?,
      stop_reason: state.stop_reason || :completed,
      calls: sum_calls(observations),
      usage: usage,
      metadata: %{
        cases: total,
        reported_cost: cost,
        limits:
          Map.drop(limits, [
            :on_progress,
            :on_dataset,
            :dataset_split,
            :cancel,
            :call_role,
            :expires_at
          ]),
        failure_scores: Map.new(scores, &{&1.name, &1.failure_score}),
        successful_models: observations |> Enum.flat_map(&successful_models/1) |> Enum.uniq()
      }
    }
  end

  defp successful_models(observation) do
    judges =
      for call <- judge_calls(observation.metadata),
          model = Prediction.response_model(call[:response], call[:model]),
          not is_nil(model),
          do: %{role: :judge, model: model}

    Prediction.successful_models(observation.prediction) ++ judges
  end

  defp summary(%Score{} = score, observations, total) do
    values =
      for %{scores: scores} <- observations,
          {:ok, value} <- [Map.fetch(scores, score.name)],
          do: value

    %Summary{
      name: score.name,
      direction: score.direction,
      count: length(values),
      mean: mean(values),
      min: extrema(values, :min),
      max: extrema(values, :max),
      coverage: if(total == 0, do: 0.0, else: length(values) / total)
    }
  end

  defp all_attempted?(observations),
    do: Enum.all?(observations, &(&1.status in [:ok, :error]))

  defp selected_mean(observations, _scores, _selector) do
    observations |> Enum.map(& &1.metadata.selected_score) |> mean()
  end

  defp put_selection(observation, _scores, nil), do: %{observation | eligible?: false}

  defp put_selection(%Observation{status: status} = observation, scores, selector)
       when status in [:ok, :error] do
    values =
      scores
      |> Map.new(&{&1.name, &1.failure_score})
      |> Map.merge(observation.scores)

    if Enum.all?(Selector.names(selector), &is_number(values[&1])) do
      observation
      |> Map.put(:eligible?, true)
      |> put_in(
        [Access.key(:metadata), :selected_score],
        Selector.select(values, scores, selector)
      )
    else
      %{observation | eligible?: false}
    end
  end

  defp put_selection(observation, _scores, _selector), do: %{observation | eligible?: false}

  defp task_observation({:ok, %Observation{} = observation}, _tune_case, _allowance, _role),
    do: observation

  defp task_observation(outcome, tune_case, allowance, role) do
    reason =
      case outcome do
        {:exit, value} -> value
        nil -> :timeout
      end

    %Observation{
      id: tune_case.id,
      status: :error,
      eligible?: false,
      error:
        Error.Execution.Callback.exception(
          message: "evaluation worker stopped: #{inspect(reason)}",
          value: reason
        ),
      calls: if(allowance, do: %{role => allowance}, else: %{}),
      metadata: %{
        case: tune_case,
        calls_upper_bound?: not is_nil(allowance),
        reserved_calls: allowance
      }
    }
  end

  defp failed(tune_case, error) do
    %Observation{
      id: tune_case.id,
      status: :error,
      eligible?: false,
      error: error,
      metadata: %{case: tune_case}
    }
  end

  defp skipped(tune_case, reason) do
    %Observation{
      id: tune_case.id,
      status: :skipped,
      eligible?: false,
      metadata: %{case: tune_case, reason: reason}
    }
  end

  defp put_allowance(%Case{} = tune_case, allowance) do
    %{tune_case | metadata: Map.put(tune_case.metadata, :model_call_allowance, allowance)}
  end

  defp admit(chunk, nil, row_calls), do: {Enum.map(chunk, &{&1, row_calls}), []}
  defp admit(chunk, 0, _row_calls), do: {[], chunk}

  defp admit([row], budget, row_calls) do
    allowance = min(budget, row_calls || budget)
    {[{row, allowance}], []}
  end

  defp admit(chunk, budget, row_calls) do
    per_row = row_calls || 1

    {admitted, skipped, _left} =
      Enum.reduce(chunk, {[], [], budget}, fn row, {admitted, skipped, left} ->
        if left > 0 do
          allowance = min(per_row, left)
          {[{row, allowance} | admitted], skipped, left - allowance}
        else
          {admitted, [row | skipped], left}
        end
      end)

    {Enum.reverse(admitted), Enum.reverse(skipped)}
  end

  defp append(state, observations),
    do: %{state | observations: Enum.reverse(observations, state.observations)}

  defp account(%{budget: nil} = state, _observations), do: state

  defp account(state, observations) do
    used = observations |> sum_calls() |> total_calls()
    %{state | budget: max(state.budget - used, 0)}
  end

  defp lost_accounting?(observations, budget) do
    not is_nil(budget) and
      Enum.any?(observations, &Map.get(&1.metadata, :calls_upper_bound?, false))
  end

  defp interruption_status(error, allowance) do
    if not is_nil(allowance) and model_call_limit?(error), do: :interrupted, else: :error
  end

  defp model_call_limit?(%Error.Execution.Failed{cause: cause}), do: model_call_limit?(cause)
  defp model_call_limit?(%Error.Execution.LimitReached{limit: :model_calls}), do: true
  defp model_call_limit?(_error), do: false

  defp calls(%Prediction{calls: calls}), do: calls
  defp calls(nil), do: %{}

  defp sum_calls(observations) do
    Enum.reduce(observations, %{}, fn observation, acc ->
      merge_counts(acc, observation.calls)
    end)
  end

  defp merge_counts(left, right), do: Map.merge(left, right, fn _key, a, b -> a + b end)
  defp total_calls(calls), do: calls |> Map.values() |> Enum.sum()
  defp remaining(nil, _used), do: nil
  defp remaining(allowance, used), do: max(allowance - used, 0)

  defp call_usage(observation) do
    judges = Enum.map(judge_calls(observation.metadata), &Map.get(&1, :usage))
    Prediction.call_usage(observation.prediction) ++ judges
  end

  defp judge_calls(%{scores: scores}),
    do: scores |> Map.values() |> Enum.flat_map(&Map.get(&1, :judge_calls, []))

  defp judge_calls(_metadata), do: []

  defp stop_reason(expires_at, limits) do
    cond do
      limits[:cancel] && limits.cancel.() -> :cancelled
      remaining_ms(expires_at) == 0 -> :deadline
      true -> nil
    end
  end

  defp expiration(timeout) when is_integer(timeout), do: now() + timeout
  defp expiration(_timeout), do: nil

  defp remaining_ms(nil), do: :infinity
  defp remaining_ms(expires_at), do: max(expires_at - now(), 0)
  defp now, do: System.monotonic_time(:millisecond)

  defp extrema([], _), do: nil
  defp extrema(values, :min), do: Enum.min(values)
  defp extrema(values, :max), do: Enum.max(values)
  defp mean([]), do: nil
  defp mean(values), do: Enum.sum(values) / length(values)
end
