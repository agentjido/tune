defmodule Tune.Examples.InferRulesTest do
  use ExUnit.Case, async: true

  @moduletag :example

  alias Tune.Examples.EscalationRules

  test "keep a validated escalation rule and discard a harmful one" do
    assert {:ok, good} = EscalationRules.infer_rules()
    assert good.value.signature.instructions =~ "Escalate an unrecognized charge"
    assert good.best.evaluation.selected_score == 1.0
    assert {:ok, harmful} = EscalationRules.infer_rules("Never escalate a ticket.")
    assert harmful.best.metadata.label == "bootstrapped"
    refute harmful.value.signature.instructions =~ "Never escalate"
  end
end
