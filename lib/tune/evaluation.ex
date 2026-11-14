defmodule Tune.Evaluation do
  @moduledoc """
  A scored evaluation of a program over one dataset.

  Evaluation continues after row failures and retains every row. Scores are
  aggregated as follows:

    * `mean` is the mean score of successful rows, or `nil` without any
    * `coverage` is the fraction of rows that succeeded
    * `complete?` is `true` when every row was attempted
    * `eligible?` is `true` when the evaluation is complete and either no row
      failed or an explicit `failure_score` was given
    * `selection_score` is the mean across all rows, with `failure_score` for
      failed rows, when eligible; otherwise `nil`

  A run-level budget interruption is not a failed row: it leaves the
  evaluation incomplete. If a row worker is killed and the call allowance is
  limited, its reserved allowance is recorded as an upper bound and no further
  rows start.
  """

  alias Tune
  alias Tune.Error
  alias Tune.Example
  alias Tune.Metric
  alias Tune.Result

  defmodule Row do
    @moduledoc """
    One evaluated row.

    `status` is `:ok`, `:error`, `:interrupted` (stopped by the run budget), or
    `:skipped` (not started). `calls` counts attempted managed calls; when
    `calls_upper_bound?` is `true` it is the reserved allowance of a killed worker.
    """

    defstruct [
      :index,
      :id,
      :status,
      :score,
      :feedback,
      :output,
      :result,
      :error,
      calls: 0,
      calls_upper_bound?: false
    ]

    @type t :: %__MODULE__{
            index: non_neg_integer(),
            id: String.t(),
            status: :ok | :error | :interrupted | :skipped,
            score: number() | nil,
            feedback: String.t() | nil,
            output: map() | nil,
            result: Tune.Result.t() | nil,
            error: term(),
            calls: non_neg_integer(),
            calls_upper_bound?: boolean()
          }
  end

  defstruct rows: [],
            mean: nil,
            coverage: 0.0,
            selection_score: nil,
            eligible?: false,
            complete?: false,
            failure_score: nil,
            calls: 0,
            stop_reason: :completed

  @type t :: %__MODULE__{
          rows: [Row.t()],
          mean: float() | nil,
          coverage: float(),
          selection_score: float() | nil,
          eligible?: boolean(),
          complete?: boolean(),
          failure_score: number() | nil,
          calls: non_neg_integer(),
          stop_reason: :completed | :budget_exhausted | :lost_accounting
        }

  @eval_options [:metric, :failure_score, :concurrency, :row_timeout, :max_row_calls]

  @doc false
  @spec split_options(keyword()) :: {keyword(), keyword()}
  def split_options(opts), do: Keyword.split(opts, @eval_options)

  @doc false
  @spec normalize_options(keyword()) :: {:ok, keyword()} | {:error, Exception.t()}
  def normalize_options(opts) do
    with {:ok, metric} <- metric(opts),
         {:ok, failure_score} <- failure_score(opts),
         {:ok, concurrency} <- positive(opts, :concurrency, 1),
         {:ok, row_timeout} <- positive(opts, :row_timeout, 120_000),
         {:ok, max_row_calls} <- positive(opts, :max_row_calls, nil) do
      {:ok,
       [
         metric: metric,
         failure_score: failure_score,
         concurrency: concurrency,
         row_timeout: row_timeout,
         max_row_calls: max_row_calls
       ]}
    end
  end

  @doc """
  Evaluates normalized examples.

  `run_options` are normalized run options; their `:max_model_calls` is the
  total allowance for the whole evaluation. Returns the report.
  """
  @spec run(Tune.t(), [Example.t()], keyword(), keyword()) :: t()
  def run(program, examples, run_options, eval_options) do
    budget = Keyword.get(run_options, :max_model_calls)
    concurrency = Keyword.fetch!(eval_options, :concurrency)
    {:ok, supervisor} = Task.Supervisor.start_link()

    try do
      examples
      |> Enum.with_index()
      |> Enum.chunk_every(concurrency)
      |> evaluate_chunks(program, supervisor, run_options, eval_options, budget, [], :completed)
      |> then(fn {rows, stop_reason} -> summarize(rows, eval_options, stop_reason) end)
    after
      Supervisor.stop(supervisor)
    end
  end

  defp evaluate_chunks([], _program, _sup, _run, _eval, _budget, rows, reason), do: {rows, reason}

  defp evaluate_chunks(chunks, _program, _sup, _run, _eval, _budget, rows, reason)
       when reason != :completed,
       do: {rows ++ Enum.map(List.flatten(chunks), &skipped/1), reason}

  defp evaluate_chunks(
         [chunk | rest],
         program,
         sup,
         run_options,
         eval_options,
         budget,
         rows,
         :completed
       ) do
    {admitted, skipped} = admit(chunk, budget, eval_options)

    started =
      Enum.map(admitted, fn {{example, index}, allowance} ->
        options = Keyword.put(run_options, :max_model_calls, allowance)

        task =
          Task.Supervisor.async_nolink(sup, fn ->
            row_work(program, example, options, eval_options)
          end)

        {task, example, index, allowance}
      end)

    timeout = Keyword.fetch!(eval_options, :row_timeout)
    yields = Task.yield_many(Enum.map(started, &elem(&1, 0)), timeout)

    new_rows =
      Enum.zip_with(started, yields, fn {task, example, index, allowance}, {_task, outcome} ->
        outcome = outcome || Task.shutdown(task, :brutal_kill)
        to_row(outcome, example, index, allowance)
      end)

    used = Enum.sum(Enum.map(new_rows, & &1.calls))
    budget = if budget, do: max(budget - used, 0)

    reason =
      cond do
        Enum.any?(new_rows, &(&1.calls_upper_bound? and budget != nil)) -> :lost_accounting
        Enum.any?(new_rows, &(&1.status == :interrupted)) -> :budget_exhausted
        skipped != [] -> :budget_exhausted
        budget == 0 and rest != [] -> :budget_exhausted
        true -> :completed
      end

    rows = rows ++ new_rows ++ Enum.map(skipped, &skipped/1)
    evaluate_chunks(rest, program, sup, run_options, eval_options, budget, rows, reason)
  end

  defp admit(chunk, nil, _eval_options), do: {Enum.map(chunk, &{&1, nil}), []}

  defp admit(chunk, budget, eval_options) do
    cap = Keyword.get(eval_options, :max_row_calls)

    if length(chunk) == 1 do
      if budget > 0, do: {[{hd(chunk), min(budget, cap || budget)}], []}, else: {[], chunk}
    else
      per_row = cap || 1

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
  end

  defp row_work(program, example, run_options, eval_options) do
    case Tune.new_execution(program, run_options) do
      {:ok, execution} ->
        case Tune.run_with(program, example.inputs, execution) do
          {:ok, result} ->
            {:ok, result, Metric.score(Keyword.fetch!(eval_options, :metric), example, result)}

          {:error, %Error.Execution.Failed{result: result} = error} ->
            {:failed, result, error}

          {:error, error} ->
            {:failed, %Result{}, error}
        end

      {:error, error} ->
        {:failed, %Result{}, error}
    end
  end

  defp to_row({:ok, {:ok, result, {:ok, score}}}, example, index, _allowance) do
    %Row{
      index: index,
      id: example.id,
      status: :ok,
      score: score.score,
      feedback: score.feedback,
      output: result.output,
      result: result,
      calls: Result.total_calls(result)
    }
  end

  defp to_row({:ok, {:ok, result, {:error, error}}}, example, index, _allowance),
    do: error_row(example, index, result, error)

  defp to_row({:ok, {:failed, result, error}}, example, index, allowance) do
    if budget_interruption?(error, allowance) do
      %Row{
        index: index,
        id: example.id,
        status: :interrupted,
        result: result,
        error: error,
        calls: Result.total_calls(result)
      }
    else
      error_row(example, index, result, error)
    end
  end

  defp to_row(outcome, example, index, allowance) do
    reason =
      case outcome do
        {:exit, reason} -> reason
        nil -> :timeout
      end

    %Row{
      index: index,
      id: example.id,
      status: :error,
      error:
        Error.Execution.Callback.exception(
          message: "row worker stopped: #{inspect(reason)}",
          value: reason
        ),
      calls: allowance || 0,
      calls_upper_bound?: true
    }
  end

  defp error_row(example, index, result, error) do
    %Row{
      index: index,
      id: example.id,
      status: :error,
      result: result,
      error: error,
      calls: Result.total_calls(result)
    }
  end

  defp budget_interruption?(
         %Error.Execution.Failed{cause: %Error.Execution.LimitReached{limit: :model_calls}},
         allowance
       ),
       do: allowance != nil

  defp budget_interruption?(_error, _allowance), do: false

  defp skipped({example, index}), do: %Row{index: index, id: example.id, status: :skipped}

  defp summarize(rows, eval_options, stop_reason) do
    failure_score = Keyword.get(eval_options, :failure_score)
    rows = Enum.sort_by(rows, & &1.index)
    total = length(rows)
    ok = Enum.filter(rows, &(&1.status == :ok))
    failed = Enum.filter(rows, &(&1.status == :error))
    complete? = Enum.all?(rows, &(&1.status in [:ok, :error]))
    eligible? = complete? and total > 0 and (failed == [] or failure_score != nil)

    %__MODULE__{
      rows: rows,
      mean: mean(Enum.map(ok, & &1.score)),
      coverage: if(total == 0, do: 0.0, else: length(ok) / total),
      selection_score:
        if(eligible?,
          do: mean(Enum.map(ok, & &1.score) ++ List.duplicate(failure_score, length(failed))),
          else: nil
        ),
      eligible?: eligible?,
      complete?: complete?,
      failure_score: failure_score,
      calls: Enum.sum(Enum.map(rows, & &1.calls)),
      stop_reason: stop_reason
    }
  end

  defp mean([]), do: nil
  defp mean(values), do: Enum.sum(values) / length(values)

  defp metric(opts) do
    case Keyword.fetch(opts, :metric) do
      {:ok, metric} -> Metric.new(metric)
      :error -> {:error, Error.Invalid.Option.exception(option: :metric, message: "is required")}
    end
  end

  defp failure_score(opts) do
    case Keyword.get(opts, :failure_score) do
      nil ->
        {:ok, nil}

      score when is_number(score) ->
        {:ok, score}

      other ->
        {:error,
         Error.Invalid.Option.exception(
           option: :failure_score,
           message: "must be a number, got: #{inspect(other)}"
         )}
    end
  end

  defp positive(opts, key, default) do
    case Keyword.get(opts, key, default) do
      nil ->
        {:ok, nil}

      value when is_integer(value) and value > 0 ->
        {:ok, value}

      other ->
        {:error,
         Error.Invalid.Option.exception(
           option: key,
           message: "must be a positive integer, got: #{inspect(other)}"
         )}
    end
  end
end
