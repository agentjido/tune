defmodule Tune.Examples.PackKitTest do
  use ExUnit.Case, async: true

  @moduletag :example

  alias Tune.Examples.Packing

  test "the feasible kit reaches the known optimum and overweight candidates cannot win" do
    assert {:ok, result} = Packing.packing()
    assert [%{output: %{weight: 7, value: 11}}] = result.best.evaluation.observations
    assert result.value == [1, 0, 0, 1]
    assert too_heavy = Enum.find(result.history, &(&1.value == [1, 1, 1, 1]))
    refute too_heavy.evaluation.eligible?
  end
end
