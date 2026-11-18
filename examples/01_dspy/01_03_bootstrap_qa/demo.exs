%{winner: winner, holdout: holdout} = Tune.Examples.BootstrapQA.run()
IO.puts("Learned demonstrations #{inspect(winner.metadata.notes.bootstrapped)}")
IO.puts("Teacher calls #{winner.calls.teacher}")
IO.puts("Held-out answer score #{holdout.challenger.summaries.answer.mean}")
