defmodule Tune.Examples.SimbaTest do
  use ExUnit.Case, async: true

  @moduletag :example

  alias Tune.Examples.SIMBA

  test "both lesson paths improve the score and failed traces produce neither update" do
    assert {:ok, demo} = SIMBA.simba(:demo)
    assert [_ | _] = demo.value.demos
    assert demo.value.signature.instructions == "Label it."
    assert demo.best.evaluation.selected_score == 1.0
    assert {:ok, rule} = SIMBA.simba(:rule)
    assert rule.value.demos == []
    assert rule.value.signature.instructions =~ "Always answer billing."
    assert rule.best.evaluation.selected_score == 1.0
    assert {:error, %Tune.Error.Optimization.Failed{report: failed}} = SIMBA.simba(:failed)
    assert Enum.all?(failed.metadata.notes.steps, &(&1.created == []))
  end
end
