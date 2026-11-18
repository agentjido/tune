defmodule Tune.Examples.EnsembleTest do
  use ExUnit.Case, async: true

  @moduletag :example

  alias Tune.Examples.Support.Tickets
  alias Tune.Examples.Voting

  test "majority wins and ties keep the earliest member" do
    assert {:ok, %{output: %{"label" => "billing"}, calls: %{target: 3}}} =
             Voting.ensemble()

    assert {:ok, %{output: %{"label" => "bug"}}} =
             Voting.ensemble(["bug", "billing", "other"])
  end

  test "check compatible signatures and share the call allowance" do
    {:ok, other} =
      Tune.Predictor.new(
        signature: [inputs: [ticket: Zoi.string()], outputs: [urgency: Zoi.string()]]
      )

    assert {:error, %Tune.Error.Invalid.Definition{}} =
             Tune.Ensemble.new([Tickets.classifier(), other])

    assert {:error, %Tune.Error.Execution.Failed{result: %{calls: %{target: 2}}}} =
             Voting.ensemble(["bug", "billing", "billing"], 2)
  end
end
