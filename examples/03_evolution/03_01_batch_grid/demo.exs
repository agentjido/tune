{:ok, %{winner: winner, comparison: comparison}} = Tune.Examples.BatchGrid.grid()
IO.puts("Evaluated #{length(winner.history)} batch and worker combinations")
IO.puts("Selected #{inspect(winner.value)}")
IO.puts("Paired holdout improvement #{comparison.metrics.throughput.delta}")
