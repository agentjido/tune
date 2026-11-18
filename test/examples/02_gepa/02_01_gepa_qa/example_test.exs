defmodule Tune.Examples.QATest do
  @moduledoc "Examples for learning demonstrations and correcting evidence failures."
  use ExUnit.Case, async: true

  @moduletag :example

  alias Tune.Examples.Support.MultiHopQA
  alias Tune.Examples.Support.Transport

  test "reflection receives evidence gaps and records per-row strengths" do
    %{winner: winner, reflection: requests} = MultiHopQA.run(use_merge: false)
    feedback = Enum.map_join(requests, "\n", &Transport.prompt_text/1)

    assert feedback =~ "feedback: missing evidence"
    assert feedback =~ "feedback: unsupported answer"
    assert winner.best.evaluation.selected_score == 1.0

    assert Enum.any?(winner.history, fn candidate ->
             scores = Enum.map(candidate.evaluation.observations, & &1.scores.grounded)
             Enum.sort(scores) == [0, 1] and candidate.lineage != %{}
           end)
  end

  test "GEPA rejects a proposal that fails to beat its parent on the same minibatch" do
    %{winner: winner} = MultiHopQA.run(use_merge: false, proposal: "Try harder.")
    assert [baseline] = winner.history
    assert baseline.metadata.label == "baseline"
    assert Enum.all?(winner.metadata.notes.iterations, &(not &1.accepted?))
  end
end
