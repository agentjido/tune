%{winner: winner} = Tune.Examples.Support.MultiHopQA.run(seed: 0)
merge = Enum.find(winner.metadata.notes.iterations, &(&1.kind == :merge))
IO.puts("Merged parents #{inspect(merge.parents)} with ancestor #{merge.ancestor}")
IO.puts("Held-out grounded score #{winner.best.evaluation.selected_score}")
