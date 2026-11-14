defmodule Tune.Contracts.NxAxonCompatibilityTest do
  use ExUnit.Case, async: true

  alias Tune.Result

  test "generic search accepts Nx tensor streams and opaque Axon values" do
    data = fn -> Stream.map([1.0, 2.0], &Nx.tensor([[&1]])) end

    runner = fn config, tensor ->
      model = Axon.input("input", shape: {nil, 1}) |> Axon.dense(config.units)
      loss = Nx.tensor(abs(config.units - 2) + Nx.to_number(Nx.mean(tensor)) * 0.0)
      %{loss: loss, model: model, tensor: tensor}
    end

    assert {:ok, result} =
             Tune.new(%{units: 1}, run: runner)
             |> Tune.data(validation: data)
             |> Tune.vary(units: 1..3)
             |> Tune.score(:validation_loss, &Nx.to_number(&1.loss), direction: :minimize)
             |> Tune.search(:genetic, population_size: 8, generations: 1)
             |> Tune.limit(evaluations: 16, seed: 2)
             |> Tune.tune()

    assert result.value.units == 2

    assert %Axon{} =
             result.best.evaluation.observations
             |> hd()
             |> Map.fetch!(:output)
             |> Map.fetch!(:model)

    assert %Nx.Tensor{} =
             result.best.evaluation.observations
             |> hd()
             |> Map.fetch!(:output)
             |> Map.fetch!(:tensor)

    assert {:ok, artifact} = Tune.dump(result)
    assert artifact.parameters == %{"units" => 2}
    assert {:ok, %{units: 2}} = Tune.load(artifact, %{units: 1})
  end

  test "artifacts reject tensors and model state in learned parameters" do
    tensor_result = %Result{
      parameters: %{weights: Nx.tensor([1.0])},
      metadata: %{strategy: :genetic}
    }

    model_result = %Result{
      parameters: %{model: Axon.input("input", shape: {nil, 1})},
      metadata: %{strategy: :genetic}
    }

    assert {:error, %Tune.Error.Invalid.Option{option: :artifact}} = Tune.dump(tensor_result)
    assert {:error, %Tune.Error.Invalid.Option{option: :artifact}} = Tune.dump(model_result)
  end
end
