{:ok, winner} = Tune.Examples.EscalationRules.infer_rules()
IO.puts(winner.value.signature.instructions)
IO.puts("Held-out routing accuracy #{winner.best.evaluation.selected_score}")
