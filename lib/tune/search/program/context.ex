defmodule Tune.Search.Program.Context do
  @moduledoc """
  Internal operations and program data for one search strategy.

  Shared candidate, limit, accounting, random, and result state belongs to
  `Tune.Search.Study`.
  """

  alias Tune.Case
  alias Tune.Error
  alias Tune.Evaluation
  alias Tune.Program
  alias Tune.Runtime.Target
  alias Tune.Score
  alias Tune.Search.Study

  defstruct [
    :optimizer,
    :metric,
    :failure_score,
    :run_options,
    :row_timeout,
    :selector,
    :study,
    :validation_factory,
    trainset: [],
    valset: [],
    scores: []
  ]

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(opts) do
    seed = Keyword.fetch!(opts, :seed)
    limits = Keyword.get(opts, :limits, %{})
    metadata = Keyword.get(opts, :metadata, %{})

    %__MODULE__{
      optimizer: Keyword.fetch!(opts, :optimizer),
      metric: Keyword.get(opts, :metric),
      failure_score: Keyword.get(opts, :failure_score),
      run_options: Keyword.fetch!(opts, :run_options),
      row_timeout: Keyword.get(opts, :row_timeout, 120_000),
      scores: Keyword.get(opts, :scores, []),
      selector: Keyword.get(opts, :selector),
      validation_factory: Keyword.get(opts, :validation_factory, fn -> [] end),
      trainset: Keyword.get(opts, :trainset, []),
      valset: Keyword.get(opts, :valset, []),
      study:
        Study.new(
          seed: seed,
          model_calls: Keyword.get(opts, :max_model_calls),
          deadline: Keyword.get(opts, :deadline),
          limits: limits,
          metadata: metadata,
          notes: Keyword.get(opts, :notes, %{})
        )
    }
  end

  @spec exhausted?(t()) :: boolean()
  def exhausted?(%__MODULE__{study: study}), do: Study.exhausted?(study)

  @spec budget(t()) :: non_neg_integer() | nil
  def budget(%__MODULE__{study: study}), do: Study.remaining_model_calls(study)

  @spec stop_reason(t()) :: atom() | nil
  def stop_reason(%__MODULE__{study: study}), do: Study.stop_reason(study)

  @spec seed(t()) :: term()
  def seed(%__MODULE__{study: study}), do: study.seed

  @spec max_model_calls(t()) :: non_neg_integer() | nil
  def max_model_calls(%__MODULE__{study: study}), do: study.max_model_calls

  @spec incumbent(t()) :: Tune.Candidate.t() | nil
  def incumbent(%__MODULE__{study: study}), do: Study.incumbent(study)

  @spec notes(t()) :: map()
  def notes(%__MODULE__{study: study}), do: Study.notes(study)

  @spec run(t(), Program.t(), map(), atom()) ::
          {{:ok, Tune.Prediction.t()} | {:error, term()}, t()}
  def run(%__MODULE__{} = ctx, program, input, role) do
    case Study.limit_reason(ctx.study) do
      nil ->
        allowance = Study.remaining_model_calls(ctx.study)

        outcome =
          with {:ok, target} <- Target.new(program, ctx.run_options) do
            case Target.run(target, input, role: role, max_model_calls: allowance) do
              {:ok, _output, prediction} -> {:ok, prediction}
              {:error, error, _prediction} -> {:error, error}
              {:error, error} -> {:error, error}
            end
          end

        study = Study.account(ctx.study, prediction_of(outcome))

        study =
          case outcome do
            {:error,
             %Error.Execution.Failed{cause: %Error.Execution.LimitReached{limit: :model_calls}}} ->
              Study.stop(study, :budget_exhausted)

            _ ->
              study
          end

        {outcome, %{ctx | study: study}}

      reason ->
        {{:error, limit_error(reason)}, stop(ctx, reason)}
    end
  end

  @spec propose(t(), Tune.Predictor.t(), map(), atom()) :: {{:ok, map()} | {:error, term()}, t()}
  def propose(%__MODULE__{} = ctx, predictor, input, role \\ :proposal) do
    case run(ctx, predictor, input, role) do
      {{:ok, prediction}, ctx} -> {{:ok, prediction.output}, ctx}
      {{:error, error}, ctx} -> {{:error, error}, ctx}
    end
  end

  @spec evaluate(t(), Program.t(), [Case.t()]) :: {Evaluation.t(), t()}
  def evaluate(%__MODULE__{} = ctx, program, cases) do
    budget = if exhausted?(ctx), do: 0, else: Study.remaining_model_calls(ctx.study)

    runner = fn tune_case ->
      allowance = Map.get(tune_case.metadata, :model_call_allowance)

      with {:ok, target} <- Target.new(program, ctx.run_options) do
        Target.run(target, tune_case.input,
          role: :target,
          max_model_calls: allowance
        )
      end
    end

    {scores, selector} = evaluation_scores(ctx)

    evaluation =
      Tune.Evaluator.evaluate(cases, runner, scores, selector, %{
        concurrency: 1,
        row_timeout: ctx.row_timeout,
        model_calls: budget,
        deadline: Study.remaining_deadline(ctx.study)
      })

    study = Study.account_evaluation(ctx.study, evaluation)

    study =
      case evaluation.stop_reason do
        reason when reason in [:completed, :case_limit] -> study
        :model_call_limit -> Study.stop(study, :budget_exhausted)
        :lost_accounting -> study |> Study.stop(:lost_accounting) |> exhaust_budget()
        reason -> Study.stop(study, reason)
      end

    {evaluation, %{ctx | study: study}}
  end

  @spec evaluate_validation(t(), Program.t()) :: {Evaluation.t(), t()}
  def evaluate_validation(%__MODULE__{} = ctx, program) do
    evaluate(ctx, program, ctx.validation_factory.())
  end

  @spec consider(t(), Program.t(), Evaluation.t() | nil, map()) :: {String.t(), t()}
  def consider(%__MODULE__{} = ctx, program, evaluation, metadata \\ %{}) do
    {:ok, parameters} = Program.parameters(program)
    {candidate, study} = Study.record(ctx.study, program, parameters, evaluation, metadata)
    {candidate.id, %{ctx | study: study}}
  end

  @spec result(t(), term(), map(), keyword()) :: Tune.Result.t()
  def result(%__MODULE__{} = ctx, value, parameters, opts \\ []),
    do: Study.result(ctx.study, value, parameters, opts)

  @spec best(t()) :: {:ok, Program.t(), t()} | {:error, Exception.t(), t()}
  def best(%__MODULE__{} = ctx) do
    case Study.incumbent(ctx.study) do
      %Tune.Candidate{value: program} ->
        {:ok, program, ctx}

      nil ->
        {:error,
         Error.Optimization.Failed.exception(
           message: "no candidate completed an eligible validation pass"
         ), ctx}
    end
  end

  @spec best_evaluation(t()) :: Evaluation.t() | nil
  def best_evaluation(%__MODULE__{study: study}), do: Study.best_evaluation(study)

  @spec stop(t(), atom()) :: t()
  def stop(%__MODULE__{} = ctx, reason), do: %{ctx | study: Study.stop(ctx.study, reason)}

  @spec note(t(), atom(), term()) :: t()
  def note(%__MODULE__{} = ctx, key, value),
    do: %{ctx | study: Study.note(ctx.study, key, value)}

  @spec uniform(t(), pos_integer()) :: {non_neg_integer(), t()}
  def uniform(%__MODULE__{} = ctx, n) do
    {value, study} = Study.uniform(ctx.study, n)
    {value, %{ctx | study: study}}
  end

  @spec random(t()) :: {float(), t()}
  def random(%__MODULE__{} = ctx) do
    {value, study} = Study.random(ctx.study)
    {value, %{ctx | study: study}}
  end

  @spec shuffle(t(), list()) :: {list(), t()}
  def shuffle(%__MODULE__{} = ctx, list) do
    {value, study} = Study.shuffle(ctx.study, list)
    {value, %{ctx | study: study}}
  end

  @spec sample(t(), list(), non_neg_integer()) :: {list(), t()}
  def sample(%__MODULE__{} = ctx, list, count) do
    {value, study} = Study.sample(ctx.study, list, count)
    {value, %{ctx | study: study}}
  end

  @spec limit_error(atom()) :: Exception.t()
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

  @spec account_evaluation(t(), Evaluation.t()) :: t()
  def account_evaluation(%__MODULE__{} = ctx, %Evaluation{} = evaluation),
    do: %{ctx | study: Study.account_evaluation(ctx.study, evaluation)}

  @spec metric(t()) :: term()
  def metric(%__MODULE__{metric: metric}), do: metric

  @spec score(t(), Case.t(), Tune.Prediction.t()) ::
          {:ok, %{score: number(), feedback: String.t() | nil}} | {:error, term()}
  def score(%__MODULE__{metric: %Score{} = score}, %Case{} = tune_case, prediction) do
    case Score.execute(score, tune_case, prediction.output, prediction) do
      {:ok, value, _metadata} -> {:ok, value}
      {:error, error, _metadata} -> {:error, error}
    end
  end

  defp evaluation_scores(%__MODULE__{scores: []} = ctx) do
    {[ctx.metric], {:score, :objective}}
  end

  defp evaluation_scores(%__MODULE__{} = ctx), do: {ctx.scores, ctx.selector}

  defp prediction_of({:ok, %Tune.Prediction{} = prediction}), do: prediction

  defp prediction_of({:error, %Error.Execution.Failed{result: %Tune.Prediction{} = prediction}}),
    do: prediction

  defp prediction_of(_outcome), do: %Tune.Prediction{}

  defp exhaust_budget(%Study{} = study), do: %{study | budget: if(study.budget, do: 0)}
end
