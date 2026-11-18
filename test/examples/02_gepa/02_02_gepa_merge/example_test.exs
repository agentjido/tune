defmodule Tune.Examples.GEPAMergeTest do
  use ExUnit.Case, async: true

  @moduletag :example

  alias Tune.Examples.Support.MultiHopQA

  test "a merge carries both parents, a common ancestor, and a full evaluation" do
    %{winner: winner} = MultiHopQA.run(seed: 0)
    assert merge = Enum.find(winner.metadata.notes.iterations, &(&1.kind == :merge))
    assert [a, b] = merge.parents
    assert candidate = Enum.find(winner.history, &(&1.lineage[:merged_from] == [a, b]))
    assert candidate.metadata.ancestor == merge.ancestor
    assert candidate.evaluation.selected_score == 1.0
    assert length(candidate.evaluation.observations) == 2
  end
end
