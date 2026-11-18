defmodule Tune.Examples.AxonTrainingTest do
  use ExUnit.Case, async: true

  @moduletag :example

  alias Tune.Examples.AxonTraining

  test "application training retains opaque model state but the artifact carries hyperparameters" do
    assert {:ok, report} = AxonTraining.axon()

    assert [%{output: %{trained: %Axon.ModelState{}, loss: %Nx.Tensor{}}}] =
             report.best.evaluation.observations

    assert report.best.evaluation.summaries.loss.mean <
             hd(report.history).evaluation.summaries.loss.mean

    assert {:ok, artifact} = Tune.dump(report)
    assert artifact.parameters == %{"learning_rate" => report.value.learning_rate}
    assert {:ok, loaded} = Tune.load(artifact, %{learning_rate: 0.02})
    assert loaded == report.value
  end
end
