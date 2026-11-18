for method <- [:random, :tpe] do
  {:ok, winner} = Tune.Examples.SearchDemos.search(method)
  scores = Enum.map(winner.history, & &1.evaluation.selected_score)
  IO.puts("#{method} validation history #{inspect(scores)}")
end

{:ok, tpe} = Tune.Examples.SearchDemos.search(:tpe)
IO.puts("Native TPE choices after startup #{inspect(Enum.drop(tpe.metadata.notes.trials, 3))}")
