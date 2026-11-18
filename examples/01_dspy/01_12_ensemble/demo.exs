{:ok, result} = Tune.Examples.Voting.ensemble()
IO.puts("Majority vote #{result.output["label"]} from #{result.calls.target} model calls")
