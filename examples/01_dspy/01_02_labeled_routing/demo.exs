%{winner: winner, holdout: holdout} = Tune.Examples.LabeledRouting.labeled()

for demo <- winner.value.demos do
  IO.puts("#{demo.inputs["ticket"]} → #{demo.outputs["label"]}")
end

IO.puts("Search model calls #{map_size(winner.calls)}")
IO.puts("Held-out accuracy #{holdout.challenger.summaries.route.mean}")
