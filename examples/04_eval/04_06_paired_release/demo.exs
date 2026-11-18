{:ok, %{comparison: comparison, decision: decision}} = Tune.Examples.ReleaseGate.run()
route = comparison.metrics.route

IO.puts(
  "Mean routing change #{route.delta} across #{route.paired_count}/#{length(comparison.case_ids)} pairs"
)

IO.puts("Critical case #{comparison.rows["critical"].metrics.route.status}")
IO.puts("Release decision #{decision}")
