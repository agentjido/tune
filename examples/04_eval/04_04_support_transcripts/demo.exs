{:ok, report} = Tune.Examples.SupportTranscripts.transcripts()

for row <- report.observations do
  IO.puts("#{row.id} scores #{inspect(row.scores)} errors #{inspect(row.score_errors)}")
end
