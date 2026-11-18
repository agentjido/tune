{:ok, report} = Tune.Examples.StreamedCSV.csv()

for {name, score} <- Enum.sort(report.summaries) do
  IO.puts("#{name} mean #{score.mean} coverage #{score.coverage} direction #{score.direction}")
end

IO.puts("Accuracy including parse failures #{report.selected_score}")
