defmodule Tune.Examples.EvolveStringTest do
  use ExUnit.Case, async: true

  @moduletag :example

  alias Tune.Examples.Spelling

  test "generation zero keeps duplicate genomes and seeded evolution hits the target" do
    assert {:ok, first} = Spelling.spelling()
    assert {:ok, second} = Spelling.spelling()
    assert first.value == second.value
    assert Enum.map(first.history, & &1.value) == Enum.map(second.history, & &1.value)
    assert first.value == "TUNE"
    assert first.stop_reason == :target_score
    assert length(Enum.uniq_by(first.history, & &1.id)) == length(first.history)
    assert first.history |> Enum.take(5) |> Enum.count(&(&1.value == "TTTT")) == 2
    assert Enum.any?(first.history, &match?(%{kind: :offspring, parents: [_, _]}, &1.lineage))
  end
end
