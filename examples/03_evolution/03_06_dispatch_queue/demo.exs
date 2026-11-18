report = fn
  %{event: :generation_evaluated} = snapshot ->
    IO.puts(
      "Generation #{snapshot.generation} best score #{snapshot.best.evaluation.selected_score}"
    )

  _event ->
    :ok
end

{:ok, winner} = Tune.Examples.Dispatch.run(on_progress: report)
IO.puts("Selected policy #{winner.value}. Stop reason #{winner.stop_reason}.")
