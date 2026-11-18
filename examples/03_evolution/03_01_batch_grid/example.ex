defmodule Tune.Examples.BatchGrid do
  @moduledoc "Search a finite grid of batch and worker settings."

  def grid(opts \\ []) do
    validate = Keyword.get(opts, :validation, fn -> [{7, 2}, {7, 2}] end)
    limits = Keyword.take(opts, [:evaluations])

    study =
      Tune.new(%{batch_size: 1, workers: 1}, run: &throughput/2)
      |> Tune.data(validation: validate, test: [{6, 2}, {8, 3}])
      |> Tune.vary(batch_size: 1..16, workers: [1, 2, 3])
      |> Tune.score(:throughput, & &1)
      |> Tune.search(:grid)
      |> Tune.limit(limits)

    with {:ok, winner} <- Tune.tune(study),
         {:ok, comparison} <- Tune.compare(study, winner, split: :test) do
      {:ok, %{winner: winner, comparison: comparison}}
    end
  end

  defp throughput(config, {size, workers}),
    do: 100 - abs(config.batch_size - size) - 3 * abs(config.workers - workers)
end
