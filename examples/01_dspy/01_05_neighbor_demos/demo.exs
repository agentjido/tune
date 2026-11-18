tickets = ["it crashes when I start it", "card payment refund"]
%{results: results, teacher_requests: neighbors} = Tune.Examples.NeighborDemos.neighbors(tickets)

for {ticket, {:ok, result}} <- Enum.zip(tickets, results) do
  IO.puts("#{ticket} → #{result.output["label"]} with #{result.calls.teacher} teacher call")
end

for body <- neighbors do
  text = Tune.Examples.Support.Transport.last_user_text(body)
  IO.puts("Selected neighbor #{Tune.Examples.Support.Offline.field(text, "ticket")}")
end
