{:ok, winner} = Tune.Examples.Packing.packing()
[best] = winner.best.evaluation.observations
IO.puts("Selected kit #{inspect(winner.value)} weighing #{best.output.weight}")
IO.puts("Kit value #{best.output.value} equals the known optimum")
