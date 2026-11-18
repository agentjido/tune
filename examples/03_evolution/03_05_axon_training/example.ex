defmodule Tune.Examples.AxonTraining do
  @moduledoc "Train an Axon model inside the application runner."

  def axon do
    batches = [{Nx.tensor([[0.0], [1.0], [2.0]]), Nx.tensor([[0.0], [2.0], [4.0]])}]
    validate = {Nx.tensor([[0.5], [1.5]]), Nx.tensor([[1.0], [3.0]])}

    Tune.new(%{learning_rate: 0.02}, run: fn config, batch -> fit(config, batches, batch) end)
    |> Tune.data(validation: [validate])
    |> Tune.vary(learning_rate: [0.02, 0.1, 0.2])
    |> Tune.score(:loss, &Nx.to_number(&1.loss), direction: :minimize)
    |> Tune.search(:grid)
    |> Tune.tune()
  end

  defp fit(config, batches, {features, expected}) do
    model =
      Axon.input("features", shape: {nil, 1})
      |> Axon.dense(1, kernel_initializer: :zeros, bias_initializer: :zeros)

    optimizer = Polaris.Optimizers.sgd(learning_rate: config.learning_rate)

    trained =
      model
      |> Axon.Loop.trainer(:mean_squared_error, optimizer, seed: 3, log: 0)
      |> Axon.Loop.run(batches, Axon.ModelState.empty(), epochs: 5)

    trained = trained.step_state.model_state
    predicted = Axon.predict(model, trained, features)
    loss = predicted |> Nx.subtract(expected) |> Nx.pow(2) |> Nx.mean()
    %{loss: loss, trained: trained}
  end
end
