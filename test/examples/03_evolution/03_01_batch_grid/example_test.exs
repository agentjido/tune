defmodule Tune.Examples.BatchGridTest do
  use ExUnit.Case, async: true

  @moduletag :example

  alias Tune.Examples.BatchGrid

  test "evaluate each combination in stable order using one validation snapshot" do
    owner = self()

    factory = fn ->
      send(owner, :read_validation)
      [{7, 2}]
    end

    assert {:ok, %{winner: result, comparison: paired}} = BatchGrid.grid(validation: factory)
    assert_received :read_validation
    refute_received :read_validation
    assert result.value == %{batch_size: 7, workers: 2}

    assert Enum.map(result.history, & &1.value) ==
             for(size <- 1..16, workers <- 1..3, do: %{batch_size: size, workers: workers})

    assert paired.metrics.throughput.delta > 0
    assert paired.case_ids == ["0", "1"]
  end

  test "the evaluation ceiling stops at the exact number of configurations" do
    assert {:ok, %{winner: result}} = BatchGrid.grid(evaluations: 4)
    assert length(result.history) == 4
    assert result.stop_reason == :evaluation_limit
    refute result.complete?
  end
end
