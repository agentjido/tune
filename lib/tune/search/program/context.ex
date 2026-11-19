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
  alias Tune.Score.Selector
  alias Tune.Search.Study

  defstruct [
    :optimizer,
    :failure_score,
    :run_options,
    :selector,
    :study,
    train: [],
    validation: [],
    scores: []
  ]

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      optimizer: Keyword.fetch!(opts, :optimizer),
      failure_score: Keyword.get(opts, :failure_score),
      run_options: Keyword.fetch!(opts, :run_options),
      scores: Keyword.get(opts, :scores, []),
      selector: Keyword.get(opts, :selector),
      train: Keyword.get(opts, :train, []),
      validation: Keyword.get(opts, :validation, []),
      study: Keyword.get_lazy(opts, :study, fn -> Study.new(opts) end)
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
        limits = Study.evaluation_limits(ctx.study) |> Map.drop([:cases, :on_progress])
        limits = Map.merge(limits, %{concurrency: 1, call_role: role})
        runner = target_runner(program, ctx.run_options, role, limits[:deadline])

        evaluation =
          Tune.Evaluator.evaluate([%Case{id: "training", input: input}], runner, [], nil, limits)

        study = Study.account_score(ctx.study, evaluation)

        outcome =
          case evaluation.observations do
            [%{status: :ok, prediction: %Tune.Prediction{} = prediction}] -> {:ok, prediction}
            [%{error: error}] when not is_nil(error) -> {:error, error}
            _ -> {:error, limit_error(evaluation.stop_reason)}
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
    limits = Study.evaluation_limits(ctx.study)
    runner = target_runner(program, ctx.run_options, :target, limits[:deadline])

    case Study.limit_reason(ctx.study) do
      nil ->
        evaluation = Tune.Evaluator.evaluate(cases, runner, ctx.scores, ctx.selector, limits)
        {evaluation, %{ctx | study: Study.account_evaluation(ctx.study, evaluation)}}

      reason ->
        {%Evaluation{stop_reason: reason}, stop(ctx, reason)}
    end
  end

  defp target_runner(program, run_options, role, deadline) do
    options = options_with_deadline(run_options, deadline)

    fn tune_case ->
      with {:ok, target} <- Target.new(program, options) do
        Target.run(target, tune_case.input,
          role: role,
          max_model_calls: Map.get(tune_case.metadata, :model_call_allowance)
        )
      end
    end
  end

  @spec evaluate_validation(t(), Program.t()) :: {Evaluation.t(), t()}
  def evaluate_validation(%__MODULE__{} = ctx, program) do
    evaluate(ctx, program, ctx.validation)
  end

  @spec consider(t(), Program.t(), Evaluation.t() | nil, map()) :: {String.t(), t()}
  def consider(%__MODULE__{} = ctx, program, evaluation, metadata \\ %{}) do
    {:ok, parameters} = Program.parameters(program)
    {candidate, study} = Study.record(ctx.study, program, parameters, evaluation, metadata)

    Study.emit(study, %{
      event: :candidate_evaluated,
      candidate_id: candidate.id,
      selected_score: evaluation && evaluation.selected_score
    })

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
  def limit_error(reason \\ :budget_exhausted) do
    {limit, message} =
      case reason do
        :deadline -> {:timeout, "optimization deadline reached"}
        :cancelled -> {:cancelled, "optimization cancelled"}
        :evaluation_limit -> {:evaluations, "optimization evaluation limit reached"}
        _ -> {:model_calls, "optimization call limit reached"}
      end

    Error.Execution.LimitReached.exception(limit: limit, message: message)
  end

  @spec score(t(), Case.t(), Tune.Prediction.t()) ::
          {{:ok, %{score: number(), feedback: String.t() | nil}} | {:error, term()}, t()}
  def score(%__MODULE__{} = ctx, %Case{} = tune_case, prediction) do
    limits = Study.evaluation_limits(ctx.study) |> Map.drop([:cases, :on_progress])
    available = limits[:model_calls]
    row_calls = limits[:row_calls]
    row_left = if row_calls, do: max(row_calls - Tune.Prediction.total_calls(prediction), 0)
    allowance = min(available || :infinity, row_left || :infinity)

    budget =
      if Enum.any?(ctx.scores, &Score.model_calls?/1) and allowance != :infinity,
        do: allowance

    limits = Map.merge(limits, %{model_calls: budget, concurrency: 1, call_role: :judge})
    runner = fn _case -> {:score_prediction, prediction} end
    evaluation = Tune.Evaluator.evaluate([tune_case], runner, ctx.scores, ctx.selector, limits)
    study = Study.account_score(ctx.study, evaluation)

    outcome =
      case evaluation.observations do
        [%{scores: values, feedback: feedback, error: error}] ->
          if Enum.all?(Selector.names(ctx.selector), &Map.has_key?(values, &1)) do
            score = Selector.select(values, ctx.scores, ctx.selector)
            feedback = score_feedback(values, feedback)
            {:ok, %{score: score, feedback: feedback}}
          else
            {:error, error || limit_error(evaluation.stop_reason)}
          end

        [] ->
          {:error, limit_error(evaluation.stop_reason)}
      end

    {outcome, %{ctx | study: study}}
  end

  defp score_feedback(values, feedback) when map_size(values) == 1,
    do: feedback |> Map.values() |> List.first()

  defp score_feedback(values, feedback) do
    Enum.map_join(values, "; ", fn {name, value} ->
      "#{name}=#{value}" <> if(feedback[name], do: " (#{feedback[name]})", else: "")
    end)
  end

  defp options_with_deadline(options, nil), do: options

  defp options_with_deadline(options, timeout),
    do: Keyword.update!(options, :timeout, &min(&1, timeout))
end
