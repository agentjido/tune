# Run with: mix run examples/generic_genetic.exs

runner = fn config, workload ->
  %{quality: 100 - abs(config.batch_size - workload)}
end

study =
  Tune.new(%{batch_size: 1}, run: runner)
  |> Tune.data(validation: fn -> Stream.map([7, 7, 7], & &1) end)
  |> Tune.vary(batch_size: 1..10)
  |> Tune.score(:quality, & &1.quality)
  |> Tune.search(:genetic,
    population_size: 10,
    generations: 3,
    mutation_rate: 0.3
  )
  |> Tune.limit(evaluations: 40, seed: 7)

{:ok, result} = Tune.tune(study)
{:ok, artifact} = Tune.dump(result)
{:ok, loaded} = Tune.load(artifact, %{batch_size: 1})

IO.puts("Selected batch size: #{result.value.batch_size}")
IO.puts("Selected score: #{result.best.evaluation.selected_score}")
IO.puts("Reloaded configuration: #{inspect(loaded)}")
