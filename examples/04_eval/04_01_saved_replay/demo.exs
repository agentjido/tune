{:ok, report} = Tune.Examples.SavedReplay.run()
IO.puts("Replayed #{inspect(Enum.map(report.observations, & &1.id))}")
IO.puts("Target calls #{Map.get(report.calls, :target, 0)}")
