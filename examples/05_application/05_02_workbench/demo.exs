run = Tune.Examples.Workbench.run()
IO.puts("Saved-answer accuracy #{run.saved.result.summaries.route.mean}")

IO.puts(
  "Training rows #{run.search.evidence.datasets.train.source.rows} → #{run.search.evidence.datasets.train.effective.rows} effective cases"
)

IO.puts(
  "Comparison split #{run.comparison.result.split} improved #{run.comparison.result.metrics.route.counts.improved} case"
)

IO.puts("Artifact download status #{run.download.status}")
