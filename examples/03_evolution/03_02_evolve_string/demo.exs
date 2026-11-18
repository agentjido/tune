{:ok, winner} = Tune.Examples.Spelling.spelling()

IO.puts(
  "Generation zero #{inspect(for item <- winner.history, item.lineage.generation == 0, do: item.value)}"
)

IO.puts("Selected #{winner.value} in generation #{winner.best.lineage.generation}")
IO.puts("Stop reason #{winner.stop_reason}")
