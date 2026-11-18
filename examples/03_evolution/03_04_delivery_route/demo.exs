{:ok, winner} = Tune.Examples.Delivery.delivery()
IO.puts("Selected route #{inspect(winner.value)}")
IO.puts("Round-trip distance #{winner.best.evaluation.summaries.distance.mean}")
