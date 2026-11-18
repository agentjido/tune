{:ok, winner} = Tune.Examples.Support.SupportGuide.playbook()
IO.puts("Selected support lessons #{inspect(winner.value.lessons.value)}")
IO.puts("Held-out urgency accuracy #{winner.best.evaluation.selected_score}")
