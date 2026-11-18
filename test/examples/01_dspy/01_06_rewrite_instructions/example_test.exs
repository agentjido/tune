defmodule Tune.Examples.RewriteInstructionsTest do
  use ExUnit.Case, async: true

  @moduletag :example

  alias Tune.Examples.RewriteInstructions
  alias Tune.Examples.Support.GroundedQA

  test "named search leaves other instructions intact and both optimizers retain the first tie" do
    for strategy <- [:signature_optimizer, :copro] do
      assert {:ok, report} = RewriteInstructions.rewrite(strategy)
      assert report.value.extract == GroundedQA.new().extract
      assert report.value.answer.signature.instructions == "Cite the passage id and answer."
      assert report.best.evaluation.selected_score == 1.0
      assert Enum.count(report.history, &(&1.evaluation.selected_score == 1.0)) >= 2
    end
  end
end
