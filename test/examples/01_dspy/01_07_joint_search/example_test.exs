defmodule Tune.Examples.JointSearchTest do
  use ExUnit.Case, async: true

  @moduletag :example

  alias Tune.Examples.JointSearch

  test "a high-scoring minibatch instruction loses to the full-validation winner" do
    assert {:ok, report} = JointSearch.mipro()
    assert report.value.signature.instructions == "Be exact."
    assert [_ | _] = report.value.demos
    assert report.best.evaluation.selected_score == 1.0

    assert Enum.any?(report.metadata.notes.trials, fn trial ->
             trial.choice["root.instruction"] == 1 and trial.score == 1.0
           end)

    assert length(report.best.evaluation.observations) == 3
    assert Map.keys(report.calls) |> Enum.sort() == [:proposal, :target, :teacher]
  end

  test "the three roles share the call ceiling" do
    assert {:ok, limited} = JointSearch.mipro(model_calls: 25)
    refute limited.complete?
    assert limited.stop_reason == :budget_exhausted
    assert Enum.sum(Map.values(limited.calls)) <= 25
    assert limited.best.evaluation.complete?
  end
end
