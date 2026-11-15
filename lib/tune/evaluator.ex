defmodule Tune.Evaluator do
  @moduledoc false

  alias Tune.Case
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
          started_at: integer()
        }

  @spec evaluate(Enumerable.t(), (Case.t() -> term()), [Score.t()], term(), map()) ::
          Evaluation.t()
  def evaluate(source, runner, scores, selector, limits) do
    started_at = System.monotonic_time(:millisecond)
    concurrency = Map.get(limits, :concurrency, 1)
    {:ok, supervisor} = Task.Supervisor.start_link()

    state = %{
      observations: [],
      budget: Map.get(limits, :model_calls),
      stop_reason: nil,
      started_at: started_at
    }

    try do
      source
      |> Stream.with_index()
      |> maybe_take_extra(limits[:cases])
      |> Stream.map(fn {value, index} -> {normalize_case(value, index), index} end)
      |> Stream.chunk_every(concurrency)
      |> Enum.reduce_while(state, fn chunk, state ->
        reduce_chunk(chunk, state, supervisor, runner, scores, limits)
      end)
      |> summarize(scores, selector, limits)
    after
      Supervisor.stop(supervisor)
    end
  end

  defp reduce_chunk(chunk, %{stop_reason: reason} = state, _supervisor, _runner, _scores, _limits)
       when not is_nil(reason) do
    observations = Enum.map(chunk, fn {tune_case, _index} -> skipped(tune_case, reason) end)
    {:halt, append(state, observations)}
  end

  defp reduce_chunk(chunk, state, supervisor, runner, scores, limits) do
    {chunk, limited?} = case_limited(chunk, limits[:cases])

    cond do
      chunk == [] ->
        {:halt, %{state | stop_reason: :case_limit}}

      deadline?(state, limits) ->
        observations =
          Enum.map(chunk, fn {tune_case, _index} -> skipped(tune_case, :deadline) end)

        {:halt, append(%{state | stop_reason: :deadline}, observations)}

      true ->
        {admitted, skipped_cases} = admit(chunk, state.budget, limits[:row_calls])

        observations =
          run_chunk(admitted, supervisor, runner, scores, Map.get(limits, :row_timeout, 120_000)) ++
            Enum.map(skipped_cases, fn {tune_case, _index} ->
              skipped(tune_case, :model_call_limit)
            end)

        state = account(append(state, observations), observations)

        stop_reason =
          cond do
            lost_accounting?(observations, state.budget) -> :lost_accounting
            Enum.any?(observations, &(&1.status == :interrupted)) -> :model_call_limit
            skipped_cases != [] -> :model_call_limit
            deadline?(state, limits) -> :deadline
            limited? -> :case_limit
            true -> nil
          end

        state = if stop_reason, do: %{state | stop_reason: stop_reason}, else: state
        if stop_reason, do: {:halt, state}, else: {:cont, state}
    end
  end

  defp run_chunk(admitted, supervisor, runner, scores, timeout) do
    tasks =
      Enum.map(admitted, fn {{tune_case, _index}, allowance} ->
        task =
          Task.Supervisor.async_nolink(supervisor, fn ->
            evaluate_case(tune_case, runner, scores, allowance)
          end)

        {task, tune_case, allowance}
      end)

    tasks
    |> Enum.map(&elem(&1, 0))
    |> Task.yield_many(timeout)
    |> Enum.zip_with(tasks, fn {_task, outcome}, {task, tune_case, allowance} ->
      outcome = outcome || Task.shutdown(task, :brutal_kill)
      task_observation(outcome, tune_case, allowance)
    end)
  end

  defp evaluate_case(%Case{} = tune_case, runner, scores, allowance) do
    tune_case = put_allowance(tune_case, allowance)

    case invoke(runner, tune_case) do
      {:ok, output, %Prediction{} = prediction, metadata} ->
        score_case(tune_case, output, prediction, metadata, scores, allowance)

      {:ok, output, nil, metadata} ->
        score_case(tune_case, output, nil, metadata, scores, allowance)

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
      {:ok, output, %Prediction{} = prediction} -> {:ok, output, prediction, %{}}
      {:ok, output, %Prediction{} = prediction, metadata} -> {:ok, output, prediction, metadata}
      {:ok, output, metadata} when is_map(metadata) -> {:ok, output, nil, metadata}
      {:ok, output} -> {:ok, output, nil, %{}}
      {:error, error, %Prediction{} = prediction} -> {:error, error, prediction, %{}}
      {:error, error} -> {:error, error, nil, %{}}
      output -> {:ok, output, nil, %{}}
    end
  end

  defp score_case(tune_case, output, prediction, metadata, scores, allowance) do
    initial_calls = calls(prediction)

    Enum.reduce_while(scores, {%{}, %{}, %{}, %{}}, fn score,
                                                       {values, feedback, score_metadata,
                                                        score_calls} ->
      used = total_calls(merge_counts(initial_calls, score_calls))
      score_case = put_allowance(tune_case, remaining(allowance, used))

      case apply_score(score, score_case, output, prediction) do
        {:ok, value, result_metadata} ->
          {:cont,
           {Map.put(values, score.name, value.score),
            Map.put(feedback, score.name, value.feedback),
            Map.put(score_metadata, score.name, Map.delete(result_metadata, :calls)),
            merge_counts(score_calls, Map.get(result_metadata, :calls, %{}))}}

        {:error, error, result_metadata} ->
          score_calls = merge_counts(score_calls, Map.get(result_metadata, :calls, %{}))

          score_metadata =
            Map.put(score_metadata, score.name, Map.delete(result_metadata, :calls))

          {:halt, {:error, error, score_metadata, score_calls}}
      end
    end)
    |> case do
      {:error, error, score_metadata, score_calls} ->
        %Observation{
          id: tune_case.id,
          status: interruption_status(error, allowance),
          eligible?: false,
          output: output,
          prediction: prediction,
          error: error,
          calls: merge_counts(initial_calls, score_calls),
          metadata:
            metadata
            |> Map.put(:case, tune_case)
            |> Map.put(:scores, score_metadata)
        }

      {values, feedback, score_metadata, score_calls} ->
        %Observation{
          id: tune_case.id,
          scores: values,
          feedback: feedback,
          output: output,
          prediction: prediction,
          calls: merge_counts(initial_calls, score_calls),
          metadata:
            metadata
            |> Map.put(:case, tune_case)
            |> Map.put(:scores, score_metadata)
        }
    end
  end

  defp apply_score(%Score{metric: metric}, tune_case, output, prediction) do
    Score.execute(%Score{name: :runtime, metric: metric}, tune_case, output, prediction)
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

    %Evaluation{
      observations: observations,
      summaries: summaries,
      selected_score: if(eligible?, do: selected_mean(observations, scores, selector)),
      eligible?: eligible?,
      complete?: complete?,
      stop_reason: state.stop_reason || :completed,
      calls: sum_calls(observations),
      usage: sum_usage(observations),
      metadata: %{
        cases: total,
        limits: limits,
        failure_scores: Map.new(scores, &{&1.name, &1.failure_score})
      }
    }
  end

  defp summary(%Score{} = score, observations, total) do
    values =
      for %{status: :ok, scores: values} <- observations, value = values[score.name], do: value

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

  defp selected_mean(observations, scores, selector) do
    observations
    |> Enum.map(&selected_value(&1, scores, selector))
    |> mean()
  end

  defp selected_value(%Observation{status: :ok, scores: values}, scores, selector),
    do: Selector.select(values, scores, selector)

  defp selected_value(%Observation{}, scores, selector) do
    {:ok, values} = Selector.failure_values(scores, selector)
    Selector.select(values, scores, selector)
  end

  defp put_selection(%Observation{status: :ok} = observation, scores, selector) do
    observation
    |> Map.put(:eligible?, true)
    |> put_in(
      [Access.key(:metadata), :selected_score],
      Selector.select(observation.scores, scores, selector)
    )
  end

  defp put_selection(%Observation{status: :error} = observation, scores, selector) do
    case Selector.failure_values(scores, selector) do
      {:ok, values} ->
        observation
        |> Map.put(:eligible?, true)
        |> put_in(
          [Access.key(:metadata), :selected_score],
          Selector.select(values, scores, selector)
        )

      :error ->
        %{observation | eligible?: false}
    end
  end

  defp put_selection(observation, _scores, _selector), do: %{observation | eligible?: false}

  defp task_observation({:ok, %Observation{} = observation}, _tune_case, _allowance),
    do: observation

  defp task_observation(outcome, tune_case, allowance) do
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
      calls: if(allowance, do: %{target: allowance}, else: %{}),
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

  defp normalize_case(%Case{} = tune_case, _index), do: tune_case

  defp normalize_case(%{} = value, index) do
    input = Map.get(value, :input, Map.get(value, "input", value))
    expected = Map.get(value, :expected, Map.get(value, "expected"))
    id = Map.get(value, :id, Map.get(value, "id", Integer.to_string(index)))
    metadata = Map.get(value, :metadata, Map.get(value, "metadata", %{}))
    %Case{id: to_string(id), input: input, expected: expected, metadata: metadata}
  end

  defp normalize_case(value, index),
    do: %Case{id: Integer.to_string(index), input: value, expected: nil}

  defp put_allowance(%Case{} = tune_case, allowance) do
    %{tune_case | metadata: Map.put(tune_case.metadata, :model_call_allowance, allowance)}
  end

  defp admit(chunk, nil, _row_calls), do: {Enum.map(chunk, &{&1, nil}), []}
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

  defp sum_usage(observations) do
    Enum.reduce(observations, %{input: 0, output: 0, total: 0}, fn observation, acc ->
      prediction = observation.prediction && Prediction.token_totals(observation.prediction)
      score_usage = score_usage(observation.metadata)
      usage = add_usage(prediction || empty_usage(), score_usage)
      Map.new(acc, fn {key, value} -> {key, value + usage[key]} end)
    end)
  end

  defp score_usage(%{scores: scores}) do
    scores
    |> Map.values()
    |> Enum.flat_map(&Map.get(&1, :judge_calls, []))
    |> Enum.reduce(empty_usage(), fn call, acc -> add_usage(acc, usage(Map.get(call, :usage))) end)
  end

  defp score_usage(_metadata), do: empty_usage()

  defp usage(nil), do: empty_usage()

  defp usage(value) do
    %{
      input: token(value, :input_tokens),
      output: token(value, :output_tokens),
      total: token(value, :total_tokens)
    }
  end

  defp token(value, key) do
    case Map.get(value, key) || Map.get(value, Atom.to_string(key)) do
      count when is_integer(count) -> count
      _ -> 0
    end
  end

  defp add_usage(left, right),
    do: %{
      input: left.input + right.input,
      output: left.output + right.output,
      total: left.total + right.total
    }

  defp empty_usage, do: %{input: 0, output: 0, total: 0}

  defp deadline?(state, %{deadline: deadline})
       when is_integer(deadline) and deadline >= 0 do
    System.monotonic_time(:millisecond) - state.started_at >= deadline
  end

  defp deadline?(_state, _limits), do: false

  defp case_limited(chunk, nil), do: {chunk, false}

  defp case_limited(chunk, count) do
    {allowed, extra} = Enum.split_while(chunk, fn {_case, index} -> index < count end)
    {allowed, extra != []}
  end

  defp maybe_take_extra(stream, nil), do: stream
  defp maybe_take_extra(stream, count), do: Stream.take(stream, count + 1)

  defp extrema([], _), do: nil
  defp extrema(values, :min), do: Enum.min(values)
  defp extrema(values, :max), do: Enum.max(values)
  defp mean([]), do: nil
  defp mean(values), do: Enum.sum(values) / length(values)
end
