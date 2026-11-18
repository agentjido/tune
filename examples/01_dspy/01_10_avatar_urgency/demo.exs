%{result: {:ok, winner}} = Tune.Examples.Support.SupportGuide.avatar()
IO.puts("Urgency instruction #{inspect(winner.value.urgency.signature.instructions)}")
IO.puts("Held-out urgency accuracy #{winner.best.evaluation.selected_score}")
