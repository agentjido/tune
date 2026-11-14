defmodule Tune.Optimizer.Context do
  @moduledoc """
  Normalized, immutable state for one optimization run.

  It holds the training and validation datasets, the metric and failure score,
  the fixed model configurations, the remaining managed call allowance, local
  random state, and the recorded candidates. Every model call an optimizer
  makes goes through `run/4`, `evaluate/3`, or `propose/4`, so every call is
  counted against the same ceiling before dispatch.

  A candidate becomes returnable only through `consider/4` with a complete,
  eligible evaluation. Ties keep the earlier candidate.
  """

  alias Tune
  alias Tune.Error
  alias Tune.Evaluation
  alias Tune.Example
  alias Tune.Metric
  alias Tune.Predictor
  alias Tune.Result

  defstruct [
    :optimizer,
    :metric,
    :failure_score,
    :run_options,
    :budget,
    :max_model_calls,
    :rand,
    :seed,
    :row_timeout,
    :stop_reason,
    trainset: [],
    valset: [],
    calls: %{},
    usage: %{input: 0, output: 0, total: 0},
    candidates: [],
    best: nil,
    next_id: 0,
    notes: %{}
  ]

  @type t :: %__MODULE__{}

  @doc false
  @spec new(keyword()) :: t()
  def new(opts) do
    seed = Keyword.fetch!(opts, :seed)

    %__MODULE__{
      optimizer: Keyword.fetch!(opts, :optimizer),
      metric: Keyword.get(opts, :metric),
      failure_score: Keyword.get(opts, :failure_score),
      run_options: Keyword.fetch!(opts, :run_options),
      budget: Keyword.get(opts, :max_model_calls),
      max_model_calls: Keyword.get(opts, :max_model_calls),
      rand: :rand.seed_s(:exsss, seed),
      seed: seed,
      row_timeout: Keyword.get(opts, :row_timeout, 120_000),
      trainset: Keyword.get(opts, :trainset, []),
      valset: Keyword.get(opts, :valset, []),
      notes: Keyword.get(opts, :notes, %{})
    }
  end

  @doc "Returns `true` when the managed call allowance is used up."
  @spec exhausted?(t()) :: boolean()
  def exhausted?(%__MODULE__{budget: 0}), do: true

  def exhausted?(%__MODULE__{stop_reason: reason})
      when reason in [:budget_exhausted, :lost_accounting], do: true

  def exhausted?(%__MODULE__{}), do: false

  @doc """
  Runs a program on one input map under a role, counting calls.

  Returns the run result and the updated context.
  """
  @spec run(t(), Tune.t(), map(), atom()) :: {{:ok, Result.t()} | {:error, term()}, t()}
  def run(%__MODULE__{} = ctx, program, inputs, role) do
    if exhausted?(ctx) do
      {{:error, limit_error()}, stop(ctx, :budget_exhausted)}
    else
      options =
        ctx.run_options |> Keyword.put(:role, role) |> Keyword.put(:max_model_calls, ctx.budget)

      outcome =
        with {:ok, execution} <- Tune.new_execution(program, options) do
          Tune.run_with(program, inputs, execution)
        end

      ctx = account(ctx, result_of(outcome))

      ctx =
        case outcome do
          {:error,
           %Error.Execution.Failed{cause: %Error.Execution.LimitReached{limit: :model_calls}}} ->
            stop(ctx, :budget_exhausted)

          _ ->
            ctx
        end

      {outcome, ctx}
    end
  end

  @doc """
  Calls an internal proposal predictor under the proposal role.

  Returns the validated output map or the original error.
  """
  @spec propose(t(), Predictor.t(), map(), atom()) :: {{:ok, map()} | {:error, term()}, t()}
  def propose(%__MODULE__{} = ctx, %Predictor{} = predictor, inputs, role \\ :proposal) do
    case run(ctx, predictor, inputs, role) do
      {{:ok, result}, ctx} -> {{:ok, result.output}, ctx}
      {{:error, error}, ctx} -> {{:error, error}, ctx}
    end
  end

  @doc "Evaluates a program on examples under the target role, counting calls."
  @spec evaluate(t(), Tune.t(), [Example.t()]) :: {Evaluation.t(), t()}
  def evaluate(%__MODULE__{} = ctx, program, examples) do
    budget = if exhausted?(ctx), do: 0, else: ctx.budget

    options =
      ctx.run_options |> Keyword.put(:role, :target) |> Keyword.put(:max_model_calls, budget)

    eval_options = [
      metric: ctx.metric,
      failure_score: ctx.failure_score,
      concurrency: 1,
      row_timeout: ctx.row_timeout,
      max_row_calls: nil
    ]

    evaluation = Evaluation.run(program, examples, options, eval_options)

    ctx =
      Enum.reduce(evaluation.rows, ctx, fn
        %{calls_upper_bound?: true, calls: calls}, ctx ->
          account(ctx, %Result{calls: %{target: calls}})

        %{result: %Result{} = result}, ctx ->
          account(ctx, result)

        _row, ctx ->
          ctx
      end)

    ctx =
      case evaluation.stop_reason do
        :completed -> ctx
        :lost_accounting -> %{stop(ctx, :lost_accounting) | budget: if(ctx.budget, do: 0)}
        reason -> stop(ctx, reason)
      end

    {evaluation, ctx}
  end

  @doc """
  Records a candidate and makes it the incumbent when its evaluation is
  complete, eligible, and strictly better than the current incumbent.

  Returns the candidate id and the updated context.
  """
  @spec consider(t(), Tune.t(), Evaluation.t() | nil, map()) :: {non_neg_integer(), t()}
  def consider(%__MODULE__{} = ctx, program, evaluation, meta \\ %{}) do
    id = ctx.next_id

    summary =
      Map.merge(meta, %{
        id: id,
        eligible?: evaluation != nil and evaluation.eligible?,
        complete?: evaluation != nil and evaluation.complete?,
        selection_score: evaluation && evaluation.selection_score,
        mean: evaluation && evaluation.mean,
        coverage: evaluation && evaluation.coverage,
        calls: evaluation && evaluation.calls
      })

    ctx = %{ctx | candidates: [summary | ctx.candidates], next_id: id + 1}

    ctx =
      if summary.eligible? and better?(summary, ctx.best),
        do: %{ctx | best: {summary, program, evaluation}},
        else: ctx

    {id, ctx}
  end

  @doc "Returns the incumbent program, or an error when no eligible candidate completed."
  @spec best(t()) :: {:ok, Tune.t(), t()} | {:error, Exception.t(), t()}
  def best(%__MODULE__{best: {_summary, program, _evaluation}} = ctx), do: {:ok, program, ctx}

  def best(%__MODULE__{} = ctx) do
    {:error,
     Error.Optimization.Failed.exception(
       message: "no candidate completed an eligible validation pass"
     ), ctx}
  end

  @doc "Returns the incumbent's evaluation, or `nil`."
  @spec best_evaluation(t()) :: Evaluation.t() | nil
  def best_evaluation(%__MODULE__{best: {_summary, _program, evaluation}}), do: evaluation
  def best_evaluation(%__MODULE__{}), do: nil

  @doc "Records a stop reason. The first reason wins."
  @spec stop(t(), atom()) :: t()
  def stop(%__MODULE__{stop_reason: nil} = ctx, reason), do: %{ctx | stop_reason: reason}
  def stop(%__MODULE__{} = ctx, _reason), do: ctx

  @doc "Stores a report note."
  @spec note(t(), atom(), term()) :: t()
  def note(%__MODULE__{} = ctx, key, value), do: %{ctx | notes: Map.put(ctx.notes, key, value)}

  @doc "Returns a uniform integer in `0..n-1` from local random state."
  @spec uniform(t(), pos_integer()) :: {non_neg_integer(), t()}
  def uniform(%__MODULE__{rand: rand} = ctx, n) when n > 0 do
    {value, rand} = :rand.uniform_s(n, rand)
    {value - 1, %{ctx | rand: rand}}
  end

  @doc "Returns a uniform float in `[0, 1)` from local random state."
  @spec random(t()) :: {float(), t()}
  def random(%__MODULE__{rand: rand} = ctx) do
    {value, rand} = :rand.uniform_s(rand)
    {value, %{ctx | rand: rand}}
  end

  @doc "Shuffles a list with local random state."
  @spec shuffle(t(), list()) :: {list(), t()}
  def shuffle(%__MODULE__{} = ctx, list) do
    {keyed, ctx} =
      Enum.map_reduce(list, ctx, fn item, ctx ->
        {key, ctx} = random(ctx)
        {{key, item}, ctx}
      end)

    {keyed |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)), ctx}
  end

  @doc "Samples up to `k` items without replacement."
  @spec sample(t(), list(), non_neg_integer()) :: {list(), t()}
  def sample(%__MODULE__{} = ctx, list, k) do
    {shuffled, ctx} = shuffle(ctx, list)
    {Enum.take(shuffled, k), ctx}
  end

  @doc false
  @spec limit_error() :: Exception.t()
  def limit_error,
    do:
      Error.Execution.LimitReached.exception(
        limit: :model_calls,
        message: "optimization call limit reached"
      )

  defp better?(_summary, nil), do: true

  defp better?(summary, {best, _program, _evaluation}),
    do: summary.selection_score > best.selection_score

  defp result_of({:ok, %Result{} = result}), do: result
  defp result_of({:error, %Error.Execution.Failed{result: %Result{} = result}}), do: result
  defp result_of(_outcome), do: %Result{}

  defp account(ctx, %Result{} = result) do
    used = Result.total_calls(result)
    tokens = Result.token_totals(result)

    %{
      ctx
      | calls: Map.merge(ctx.calls, result.calls, fn _role, left, right -> left + right end),
        budget: if(ctx.budget, do: max(ctx.budget - used, 0)),
        usage: %{
          input: ctx.usage.input + tokens.input,
          output: ctx.usage.output + tokens.output,
          total: ctx.usage.total + tokens.total
        }
    }
  end

  @doc false
  @spec metric(t()) :: Metric.t() | nil
  def metric(%__MODULE__{metric: metric}), do: metric
end
