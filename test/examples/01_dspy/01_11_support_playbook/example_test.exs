defmodule Tune.Examples.SupportPlaybookTest do
  use ExUnit.Case, async: true

  @moduletag :example

  alias Tune.Examples.Support.SupportGuide

  test "application code uses the selected lesson and rejects invalid or harmful changes" do
    assert {:ok, good} = SupportGuide.playbook()
    assert good.value.lessons.value == ["Urgent when a payment is blocked."]
    assert good.best.evaluation.selected_score == 1.0

    assert {:ok, harmful} = SupportGuide.playbook(["Escalate everything."])
    assert harmful.value.lessons.value == []
    assert [%{accepted?: true}] = harmful.metadata.notes.rounds

    assert List.last(harmful.history).evaluation.selected_score <
             harmful.best.evaluation.selected_score

    for lessons <- [["a", "b", "c"], [0]] do
      assert {:ok, rejected} = SupportGuide.playbook(lessons)
      assert rejected.value.lessons.value == []
      assert [%{accepted?: false}] = rejected.metadata.notes.rounds
    end
  end
end
