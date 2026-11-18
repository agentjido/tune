%{winner: winner, reflection: reflection} = Tune.Examples.Support.MultiHopQA.run(use_merge: false)
IO.puts("Held-out grounded score #{winner.best.evaluation.selected_score}")
IO.puts("Reflection requests #{length(reflection)}")

for candidate <- winner.history do
  row_scores = Map.new(candidate.evaluation.observations, &{&1.id, &1.scores.grounded})
  entry = Enum.find(winner.metadata.notes.pool, &(&1.id == candidate.id))

  IO.puts(
    "Candidate #{candidate.id} parents #{inspect(entry.parents)} scores #{inspect(row_scores)}"
  )
end
