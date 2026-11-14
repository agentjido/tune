defmodule Tune.Search.Context do
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
  alias Tune.Candidate
  alias Tune.Error
  alias Tune.Evaluation
  alias Tune.Example
  alias Tune.Metric
  alias Tune.Pipeline.Evaluator
  alias Tune.Pipeline.Score
  alias Tune.Prediction
  alias Tune.Predictor
  alias Tune.Program
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
    :deadline,
    :started_at,
    :target,
    :selector,
    trainset: [],
    valset: [],
    data: %{},
    scores: [],
    limits: %{},
    models: %{},
    metadata: %{},
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
      deadline: Keyword.get(opts, :deadline),
      started_at: System.monotonic_time(:millisecond),
      target: Keyword.get(opts, :target),
      data: Keyword.get(opts, :data, %{}),
      scores: Keyword.get(opts, :scores, []),
      selector: Keyword.get(opts, :selector),
      limits: Keyword.get(opts, :limits, %{}),
      models: Keyword.get(opts, :models, %{}),
      metadata: Keyword.get(opts, :metadata, %{}),
      trainset: Keyword.get(opts, :trainset, []),
      valset: Keyword.get(opts, :valset, []),
      notes: Keyword.get(opts, :notes, %{})
    }
  end

  @doc "Returns `true` when the managed call allowance is used up."
  @spec exhausted?(t()) :: boolean()
  def exhausted?(%__MODULE__{budget: 0}), do: true

  def exhausted?(%__MODULE__{stop_reason: reason})
      when reason in [:budget_exhausted, :model_call_limit, :lost_accounting], do: true

  def exhausted?(%__MODULE__{} = ctx), do: deadline?(ctx)

  @doc """
  Runs a program on one input map under a role, counting calls.

  Returns the run result and the updated context.
  """
  @spec run(t(), Tune.Program.t(), map(), atom()) ::
          {{:ok, Prediction.t()} | {:error, term()}, t()}
  def run(%__MODULE__{} = ctx, program, inputs, role) do
    case limit_reason(ctx) do
      nil ->
        options =
          ctx.run_options |> Keyword.put(:role, role) |> Keyword.put(:max_model_calls, ctx.budget)

        outcome =
          with {:ok, execution} <- Tune.Runtime.new_execution(program, options) do
            Tune.Runtime.run_with(program, inputs, execution)
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

      reason ->
        {{:error, limit_error(reason)}, stop(ctx, reason)}
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
  @spec evaluate(t(), Tune.Program.t(), [Example.t()]) :: {Evaluation.t(), t()}
  def evaluate(%__MODULE__{} = ctx, program, examples) do
    budget = if exhausted?(ctx), do: 0, else: ctx.budget

    runner = fn tune_case ->
      allowance = Map.get(tune_case.metadata, :model_call_allowance)

      options =
        ctx.run_options
        |> Keyword.put(:role, :target)
        |> Keyword.put(:max_model_calls, allowance)

      with {:ok, execution} <- Tune.Runtime.new_execution(program, options) do
        case Tune.Runtime.run_with(program, tune_case.input, execution) do
          {:ok, prediction} ->
            {:ok, prediction.output, prediction}

          {:error, %Error.Execution.Failed{result: prediction} = error} ->
            {:error, error, prediction}

          {:error, error} ->
            {:error, error}
        end
      end
    end

    {scores, selector} = evaluation_scores(ctx)

    evaluation =
      Evaluator.evaluate(examples, runner, scores, selector, %{
        concurrency: 1,
        row_timeout: ctx.row_timeout,
        model_calls: budget,
        deadline: remaining_deadline(ctx)
      })

    ctx = account_evaluation(ctx, evaluation)

    ctx =
      case evaluation.stop_reason do
        reason when reason in [:completed, :case_limit] -> ctx
        :model_call_limit -> stop(ctx, :budget_exhausted)
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
  @spec consider(t(), Tune.Program.t(), Evaluation.t() | nil, map()) :: {String.t(), t()}
  def consider(%__MODULE__{} = ctx, program, evaluation, meta \\ %{}) do
    id = Integer.to_string(ctx.next_id)
    {:ok, parameters} = Program.parameters(program)

    candidate = %Candidate{
      id: id,
      parameters: parameters,
      value: program,
      evaluation: evaluation,
      lineage: Map.take(meta, [:parents, :parent, :merged_from]),
      metadata: Map.drop(meta, [:parents, :parent, :merged_from])
    }

    ctx = record(ctx, candidate)

    {id, ctx}
  end

  @doc false
  @spec record(t(), Candidate.t()) :: t()
  def record(%__MODULE__{} = ctx, %Candidate{} = candidate) do
    best =
      if candidate.evaluation != nil and candidate.evaluation.eligible? and
           better?(candidate, ctx.best),
         do: candidate,
         else: ctx.best

    %{
      ctx
      | candidates: [candidate | ctx.candidates],
        best: best,
        next_id: ctx.next_id + 1
    }
  end

  @doc false
  @spec result(t(), term(), map(), keyword()) :: Result.t()
  def result(%__MODULE__{} = ctx, value, parameters, opts \\ []) do
    %Result{
      value: value,
      parameters: parameters,
      baseline: Keyword.get(opts, :baseline),
      best: ctx.best,
      history: Enum.reverse(ctx.candidates),
      complete?: Keyword.get(opts, :complete?, ctx.stop_reason == nil),
      stop_reason: Keyword.get(opts, :stop_reason, ctx.stop_reason || :completed),
      calls: ctx.calls,
      usage: ctx.usage,
      metadata: Map.merge(ctx.metadata, Keyword.get(opts, :metadata, %{}))
    }
  end

  @doc "Returns the incumbent program, or an error when no eligible candidate completed."
  @spec best(t()) :: {:ok, Tune.Program.t(), t()} | {:error, Exception.t(), t()}
  def best(%__MODULE__{best: %Candidate{value: program}} = ctx), do: {:ok, program, ctx}

  def best(%__MODULE__{} = ctx) do
    {:error,
     Error.Optimization.Failed.exception(
       message: "no candidate completed an eligible validation pass"
     ), ctx}
  end

  @doc "Returns the incumbent's evaluation, or `nil`."
  @spec best_evaluation(t()) :: Evaluation.t() | nil
  def best_evaluation(%__MODULE__{best: %Candidate{evaluation: evaluation}}), do: evaluation
  def best_evaluation(%__MODULE__{}), do: nil

  @doc "Records a stop reason. The first reason wins."
  @spec stop(t(), atom()) :: t()
  def stop(%__MODULE__{} = ctx, :budget_exhausted) do
    if deadline?(ctx), do: stop(ctx, :deadline), else: put_stop(ctx, :budget_exhausted)
  end

  def stop(%__MODULE__{} = ctx, reason), do: put_stop(ctx, reason)

  defp put_stop(%__MODULE__{stop_reason: nil} = ctx, reason), do: %{ctx | stop_reason: reason}
  defp put_stop(%__MODULE__{} = ctx, _reason), do: ctx

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
  def limit_error(reason \\ :budget_exhausted),
    do:
      Error.Execution.LimitReached.exception(
        limit: if(reason == :deadline, do: :timeout, else: :model_calls),
        message:
          if(reason == :deadline,
            do: "optimization deadline reached",
            else: "optimization call limit reached"
          )
      )

  defp better?(_candidate, nil), do: true

  defp better?(candidate, best),
    do: candidate.evaluation.selected_score > best.evaluation.selected_score

  defp limit_reason(%__MODULE__{} = ctx) do
    cond do
      deadline?(ctx) ->
        :deadline

      ctx.budget == 0 ->
        :budget_exhausted

      ctx.stop_reason in [:budget_exhausted, :model_call_limit, :lost_accounting, :deadline] ->
        ctx.stop_reason

      true ->
        nil
    end
  end

  defp deadline?(%__MODULE__{deadline: nil}), do: false
  defp deadline?(%__MODULE__{deadline: :infinity}), do: false

  defp deadline?(%__MODULE__{deadline: deadline, started_at: started_at}) do
    System.monotonic_time(:millisecond) - started_at >= deadline
  end

  defp remaining_deadline(%__MODULE__{deadline: nil}), do: nil
  defp remaining_deadline(%__MODULE__{deadline: :infinity}), do: nil

  defp remaining_deadline(%__MODULE__{deadline: deadline, started_at: started_at}) do
    max(deadline - (System.monotonic_time(:millisecond) - started_at), 0)
  end

  defp evaluation_scores(%__MODULE__{scores: []} = ctx) do
    {[%Score{name: :objective, metric: ctx.metric, failure_score: ctx.failure_score}],
     {:score, :objective}}
  end

  defp evaluation_scores(%__MODULE__{} = ctx), do: {ctx.scores, ctx.selector}

  defp result_of({:ok, %Prediction{} = result}), do: result
  defp result_of({:error, %Error.Execution.Failed{result: %Prediction{} = result}}), do: result
  defp result_of(_outcome), do: %Prediction{}

  defp account(ctx, %Prediction{} = result) do
    used = Prediction.total_calls(result)
    tokens = Prediction.token_totals(result)

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
  @spec account_evaluation(t(), Evaluation.t()) :: t()
  def account_evaluation(ctx, %Evaluation{} = evaluation) do
    used = evaluation.calls |> Map.values() |> Enum.sum()

    %{
      ctx
      | calls: Map.merge(ctx.calls, evaluation.calls, fn _role, left, right -> left + right end),
        budget: if(ctx.budget, do: max(ctx.budget - used, 0)),
        usage: %{
          input: ctx.usage.input + evaluation.usage.input,
          output: ctx.usage.output + evaluation.usage.output,
          total: ctx.usage.total + evaluation.usage.total
        }
    }
  end

  @doc false
  @spec metric(t()) :: Metric.t() | nil
  def metric(%__MODULE__{metric: metric}), do: metric
end
