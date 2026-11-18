defmodule Tune.Examples.RoutingPolicyTest do
  use ExUnit.Case, async: true

  @moduletag :example

  alias Tune.Examples.Support.Policy

  test "invalid proposals skip evaluation and a valid policy reloads into fresh trusted code" do
    assert {:ok, winner} = Policy.optimize()

    assert [%{child_minibatch: nil, accepted?: false}, %{accepted?: true}] =
             winner.metadata.notes.iterations

    assert length(winner.history) == 2
    assert winner.calls == %{proposal: 2}
    assert winner.value.standard_queue == Policy.new().standard_queue
    assert {:ok, artifact} = Tune.dump(winner)
    assert {:ok, loaded} = Tune.load(artifact, Policy.new())
    assert loaded.policy.value == %{"threshold" => 0.6, "queue" => "risk-review"}
  end
end
