%{comparison: comparison, prompt: prompt} = Tune.Examples.BootstrapQAComparison.run()
answer = comparison.metrics.answer

IO.puts("Test answer accuracy: #{answer.baseline_mean} -> #{answer.challenger_mean}")
IO.puts("Answer rows: #{answer.counts.improved} improved, #{answer.counts.regressed} regressed")

IO.puts(
  "Model calls: #{comparison.baseline.calls.target} -> #{comparison.challenger.calls.target}"
)

IO.puts("\nOptimized structured prompt:")

for message <- prompt.context.messages do
  body = Enum.map_join(message.content, "", & &1.text)
  IO.puts("\n[#{message.role}]\n#{body}")
end
