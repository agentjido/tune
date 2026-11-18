{:ok, report} = Tune.Examples.Retrieval.run()
IO.puts("Faithfulness #{report.summaries.faithfulness.mean}")
IO.puts("Context precision #{Float.round(report.summaries.precision.mean, 4)}")
IO.puts("Judge calls #{report.calls.judge}")
