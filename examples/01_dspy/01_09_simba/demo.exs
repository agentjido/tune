for path <- [:demo, :rule] do
  {:ok, winner} = Tune.Examples.SIMBA.simba(path)
  IO.puts("#{path} path scored #{winner.best.evaluation.selected_score}")
  IO.puts("Demonstrations #{length(winner.value.demos)}")
  IO.puts("Instruction #{inspect(winner.value.signature.instructions)}")
end
