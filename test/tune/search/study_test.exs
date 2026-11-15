defmodule Tune.Search.StudyTest do
  use ExUnit.Case, async: true

  alias Tune.Evaluation
  alias Tune.Search.Study

  test "the earlier eligible candidate wins a tie" do
    study = Study.new(seed: 7)
    evaluation = evaluation(1.0)

    {first, study} = Study.record(study, :first, %{}, evaluation)
    {_second, study} = Study.record(study, :second, %{}, evaluation)

    assert Study.incumbent(study).id == first.id
    assert Study.incumbent(study).value == :first
  end

  test "an incomplete or ineligible candidate cannot win" do
    study = Study.new(seed: 7)
    {_candidate, study} = Study.record(study, :good, %{}, evaluation(1.0))

    incomplete = %{evaluation(9.0) | complete?: false}
    ineligible = %{evaluation(10.0) | eligible?: false}

    {_candidate, study} = Study.record(study, :incomplete, %{}, incomplete)
    {_candidate, study} = Study.record(study, :ineligible, %{}, ineligible)

    assert Study.incumbent(study).value == :good
  end

  test "the first stop reason wins" do
    study = Study.new() |> Study.stop(:cancelled) |> Study.stop(:deadline)
    assert Study.stop_reason(study) == :cancelled
  end

  test "evaluation accounting is added once" do
    study = Study.new(model_calls: 10)

    evaluation = %Evaluation{
      calls: %{target: 2, judge: 1},
      usage: %{input: 4, output: 3, total: 7}
    }

    study = Study.account_evaluation(study, evaluation)

    assert study.calls == %{target: 2, judge: 1}
    assert study.usage == %{input: 4, output: 3, total: 7}
    assert study.budget == 7
    assert study.evaluations == 1
  end

  test "random state is deterministic and evaluation limits stop work" do
    left = Study.new(seed: 11, limits: %{evaluations: 1})
    right = Study.new(seed: 11, limits: %{evaluations: 1})

    {left_value, left} = Study.uniform(left, 100)
    {right_value, _right} = Study.uniform(right, 100)

    assert left_value == right_value
    refute Study.exhausted?(left)

    left = Study.account_evaluation(left, %Evaluation{})
    assert Study.limit_reason(left) == :evaluation_limit
  end

  defp evaluation(score) do
    %Evaluation{selected_score: score, complete?: true, eligible?: true}
  end
end
