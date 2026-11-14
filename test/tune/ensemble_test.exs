defmodule Tune.EnsembleTest do
  use ExUnit.Case, async: true

  alias Tune
  alias Tune.Adapter
  alias Tune.Ensemble
  alias Tune.Error
  alias Tune.Parameters
  alias Tune.Predictor
  alias Tune.TestSupport.Transport

  defp config(stub),
    do: [
      model: Transport.model(),
      adapter: Adapter.Chat,
      request_options: Transport.request_options(stub)
    ]

  defp member(instructions) do
    {:ok, predictor} =
      Predictor.new(
        signature: [
          instructions: instructions,
          inputs: [ticket: Zoi.string()],
          outputs: [label: Zoi.string()]
        ]
      )

    predictor
  end

  defp voting_stub(votes) do
    Transport.respond_with(fn body ->
      prompt = Transport.prompt_text(body)
      {_, label} = Enum.find(votes, fn {marker, _} -> prompt =~ marker end)
      Transport.chat(label: label)
    end)
  end

  test "construction makes no calls and rejects empty or incompatible members" do
    {:ok, other} =
      Predictor.new(
        signature: [inputs: [ticket: Zoi.string()], outputs: [priority: Zoi.string()]]
      )

    assert {:error, %Error.Invalid.Definition{}} = Ensemble.new([])
    assert {:error, %Error.Invalid.Definition{}} = Ensemble.new([member("A"), other])

    assert {:error, %Error.Invalid.Option{option: :reducer}} =
             Ensemble.new([member("A")], reducer: :mean)

    assert {:ok, %Ensemble{}} = Ensemble.new([member("A"), member("B")])
  end

  test "majority vote uses canonical equality and the earliest member wins ties" do
    {:ok, ensemble} = Ensemble.new([member("Vote A"), member("Vote B"), member("Vote C")])

    stub = voting_stub([{"Vote A", "bug"}, {"Vote B", "billing"}, {"Vote C", "billing"}])
    assert {:ok, result} = Tune.run(ensemble, %{ticket: "x"}, model: config(stub))
    assert result.output == %{"label" => "billing"}
    assert Enum.map(result.steps, & &1.name) == ["m0.root", "m1.root", "m2.root"]

    tie = voting_stub([{"Vote A", "bug"}, {"Vote B", "billing"}, {"Vote C", "other"}])

    assert {:ok, %{output: %{"label" => "bug"}}} =
             Tune.run(ensemble, %{ticket: "x"}, model: config(tie))
  end

  test "a custom reducer is trusted code and its failures are reported" do
    stub = voting_stub([{"Vote A", "bug"}, {"Vote B", "billing"}])
    joined = fn outputs -> %{"label" => Enum.map_join(outputs, "+", & &1["label"])} end

    {:ok, ensemble} = Ensemble.new([member("Vote A"), member("Vote B")], reducer: joined)

    assert {:ok, %{output: %{"label" => "bug+billing"}}} =
             Tune.run(ensemble, %{ticket: "x"}, model: config(stub))

    {:ok, failing} =
      Ensemble.new([member("Vote A"), member("Vote B")], reducer: fn _ -> raise "no" end)

    assert {:error, %Error.Execution.Failed{cause: %Error.Execution.Callback{}, result: result}} =
             Tune.run(failing, %{ticket: "x"}, model: config(stub))

    assert length(result.steps) == 2
  end

  test "members share one call allowance" do
    stub = voting_stub([{"Vote", "bug"}])
    {:ok, ensemble} = Ensemble.new([member("Vote A"), member("Vote B"), member("Vote C")])

    assert {:error,
            %Error.Execution.Failed{
              cause: %Error.Execution.LimitReached{limit: :model_calls},
              result: result
            }} =
             Tune.run(ensemble, %{ticket: "x"}, model: config(stub), max_model_calls: 2)

    assert result.calls == %{target: 2}
    assert length(Transport.requests(stub)) == 2
  end

  test "prefixed names replace members immutably and survive an artifact reload" do
    {:ok, ensemble} = Ensemble.new([member("Vote A"), member("Vote B")])
    {:ok, parameters} = Tune.parameters(ensemble)
    assert Map.keys(parameters) |> Enum.sort() == ["m0.root", "m1.root"]

    {:ok, changed} = Predictor.put_instructions(member("Vote B"), "Vote B carefully.")
    {:ok, updated} = Tune.replace_parameters(ensemble, %{"m1.root" => changed})
    assert Enum.at(updated.members, 1).signature.instructions == "Vote B carefully."
    assert Enum.at(ensemble.members, 1).signature.instructions == "Vote B"

    {:ok, artifact} = Parameters.dump(updated)
    {:ok, fresh} = Ensemble.new([member("Vote A"), member("Vote B")])
    {:ok, loaded} = Parameters.apply(fresh, artifact)
    assert Enum.at(loaded.members, 1).signature.instructions == "Vote B carefully."
  end

  test "a seeded size keeps a reproducible subset in member order" do
    members = Enum.map(1..5, &member("Vote #{&1}"))
    {:ok, first} = Ensemble.new(members, size: 3, seed: 4)
    {:ok, again} = Ensemble.new(members, size: 3, seed: 4)
    assert first == again
    assert length(first.members) == 3

    indexes = Enum.map(first.members, &Enum.find_index(members, fn m -> m == &1 end))
    assert indexes == Enum.sort(indexes)
  end

  test "an ensemble evaluates like any program" do
    stub = voting_stub([{"Vote", "billing"}])
    {:ok, ensemble} = Ensemble.new([member("Vote A"), member("Vote B")])

    assert {:ok, evaluation} =
             Tune.evaluate(ensemble, [%{inputs: %{ticket: "x"}, labels: %{label: "billing"}}],
               model: config(stub),
               metric: fn ex, res ->
                 if res.output["label"] == ex.labels["label"], do: 1, else: 0
               end
             )

    assert evaluation.selection_score == 1.0
    assert evaluation.calls == 2
  end
end
