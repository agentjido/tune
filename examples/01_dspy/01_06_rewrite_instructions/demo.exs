for strategy <- [:signature_optimizer, :copro] do
  {:ok, winner} = Tune.Examples.RewriteInstructions.rewrite(strategy)
  IO.puts("#{strategy} selected #{inspect(winner.value.answer.signature.instructions)}")
  IO.puts("Held-out score #{winner.best.evaluation.selected_score}")
end
