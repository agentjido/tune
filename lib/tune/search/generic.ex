defmodule Tune.Search.Generic do
  @moduledoc false

  alias Tune.Case
  alias Tune.Dataset
  alias Tune.Error
  alias Tune.Evaluator
  alias Tune.Search.Study

  def snapshot(factory, study, strategy) do
    if Study.exhausted?(study) do
      {:ok, {[], false}}
    else
      {rows, truncated?} = Dataset.select(factory.(), study.limits[:cases])
      Dataset.report(study.limits, :validation, :source, rows)
      cases = Enum.with_index(rows, &Case.normalize/2)
      Dataset.report(study.limits, :validation, :effective, cases)
      {:ok, {cases, truncated?}}
    end
  rescue
    error ->
      {:error,
       Error.Invalid.Option.exception(
         option: strategy,
         message: "could not read validation data: #{Exception.message(error)}"
       )}
  end

  def evaluate({cases, truncated?}, runner, target, scores, selector, limits) do
    limits = Map.put(limits, :source_truncated?, truncated?)
    callback = fn tune_case -> invoke(runner, target, tune_case) end
    Evaluator.evaluate(cases, callback, scores, selector, limits)
  end

  def invoke(runner, target, %Tune.Case{input: input}) when is_function(runner, 2),
    do: runner.(target, input)

  def invoke(runner, target, _case) when is_function(runner, 1), do: runner.(target)

  def apply_parameters(target, params) do
    Enum.reduce(params, target, fn {key, value}, acc -> Map.put(acc, key, value) end)
  end

  def record(study, value, params, evaluation, lineage) do
    study = Study.account_evaluation(study, evaluation)

    {candidate, study} =
      Study.record(study, value, params, evaluation, %{lineage: lineage, metadata: %{}})

    Study.emit(
      study,
      Map.merge(Map.take(lineage, [:generation]), %{
        event: :candidate_evaluated,
        candidate_id: candidate.id,
        selected_score: evaluation.selected_score
      })
    )

    {candidate, study}
  end

  def result(study, opts) do
    metadata = Map.put(Keyword.get(opts, :metadata, %{}), :evaluations, study.evaluations)
    opts = Keyword.put(opts, :metadata, metadata)

    case Study.incumbent(study) do
      nil ->
        reason = Study.stop_reason(study) || :no_eligible_candidate

        report =
          Study.result(
            study,
            nil,
            %{},
            Keyword.merge(opts, complete?: false, stop_reason: reason)
          )

        {:error,
         Error.Optimization.Failed.exception(
           message: "no candidate completed an eligible evaluation",
           report: report
         )}

      best ->
        {:ok, Study.result(study, best.value, best.parameters, opts)}
    end
  end
end
