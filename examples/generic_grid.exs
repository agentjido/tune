runner = fn config, workload ->
  %{quality: 100 - abs(config.batch_size - workload)}
end

study =
  Tune.new(%{batch_size: 1}, run: runner)
  |> Tune.data(validation: [7], test: [6, 8])
  |> Tune.vary(batch_size: 1..16)
  |> Tune.score(:quality, fn _case, output -> output.quality end)
  |> Tune.search(:grid)

{:ok, winner} = Tune.tune(study)
{:ok, comparison} = Tune.compare(study, winner, split: :test)

IO.puts("Configurations evaluated: #{length(winner.history)}")
IO.puts("Selected batch size: #{winner.value.batch_size}")
IO.puts("Paired test improvement: #{comparison.metrics.quality.delta}")
