on_progress = fn %{rows: rows} -> IO.puts("Completed #{Enum.map_join(rows, ", ", & &1.id)}") end
on_report = fn {:ok, result} -> IO.puts("Routing score #{result.summaries.routed.mean}") end
{:ok, _result} = Tune.Examples.Background.run(on_progress, on_report)
