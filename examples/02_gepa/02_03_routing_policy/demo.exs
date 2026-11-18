alias Tune.Examples.Support.Policy

{:ok, winner} = Policy.optimize()
{:ok, artifact} = Tune.dump(winner)
{:ok, loaded} = Tune.load(artifact, Policy.new())
IO.puts("Reloaded routing policy #{inspect(loaded.policy.value)}")
IO.puts("Held-out routing accuracy #{winner.best.evaluation.selected_score}")
