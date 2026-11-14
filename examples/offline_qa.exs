# Run with: MIX_ENV=test mix run examples/offline_qa.exs
# Req.Test supplies every reply. No external provider is contacted.
# The target returns the correct answer only when its prompt contains demos.
# This scripted rule demonstrates the API flow; it does not measure model quality.

alias Tune
alias Tune.Adapter
alias Tune.Examples.GroundedQA
alias Tune.ModelConfig
alias Tune.Optimizers.BootstrapFewShotWithRandomSearch
alias Tune.Parameters
alias Tune.Predictor
alias Tune.TestSupport.QAWorld
alias Tune.TestSupport.Transport

unless Code.ensure_loaded?(QAWorld) do
  raise "Run this example with MIX_ENV=test to load the offline reply helpers."
end

trainset =
  QAWorld.rows([
    {"Where is the Eiffel Tower?", "eiffel-tower", "Paris"},
    {"Who wrote Pride and Prejudice?", "pride-and-prejudice", "Jane Austen"}
  ])

valset = QAWorld.rows([{"Which gas do plants absorb?", "plants", "carbon dioxide"}])
testset = QAWorld.rows([{"What is the largest planet?", "largest-planet", "Jupiter"}])

metric = fn example, result ->
  correct? =
    result.output["answer"] == example.labels["answer"] and
      result.output["sources"] == example.labels["sources"]

  %{
    score: if(correct?, do: 1.0, else: 0.0),
    feedback:
      if(correct?, do: "Correct answer and sources.", else: "Check the answer and sources.")
  }
end

for {name, adapter, options} <- [
      {"chat", Adapter.Chat, []},
      {"json", Adapter.JSON, [mode: :text]},
      {"xml", Adapter.XML, []}
    ] do
  target_stub =
    QAWorld.stub(
      quality: fn _prompt, answer, body ->
        if QAWorld.demos?(body), do: answer, else: "unsure"
      end
    )

  {:ok, target} =
    ModelConfig.new(
      model: Transport.model(),
      adapter: adapter,
      adapter_options: options,
      request_options: Transport.request_options(target_stub)
    )

  {:ok, teacher} =
    ModelConfig.new(
      model: Transport.model(),
      adapter: Adapter.Chat,
      request_options: Transport.request_options(QAWorld.stub())
    )

  program = GroundedQA.new()
  evaluation_options = [model: target, metric: metric, max_model_calls: 8]
  {:ok, baseline} = Tune.evaluate(program, testset, evaluation_options)

  {:ok, optimized, report} =
    Tune.optimize(program,
      optimizer:
        {BootstrapFewShotWithRandomSearch,
         accept_score: 1.0,
         num_candidate_programs: 1,
         max_bootstrapped_demos: 1,
         max_labeled_demos: 0},
      trainset: trainset,
      valset: valset,
      metric: metric,
      model: target,
      teacher: teacher,
      max_model_calls: 64,
      seed: 7
    )

  {:ok, evaluated} = Tune.evaluate(optimized, testset, evaluation_options)

  IO.puts("\n=== #{name}: offline grounded QA ===")
  IO.puts("Test score: #{baseline.selection_score} -> #{evaluated.selection_score}")
  IO.puts("Optimization calls by role (limit 64): #{inspect(report.calls)}")
  IO.puts("Stop reason: #{report.stop_reason}")

  IO.puts(
    "Learned demonstrations: extract #{length(optimized.extract.demos)}, answer #{length(optimized.answer.demos)}"
  )

  [row] = evaluated.rows

  for step <- row.result.steps do
    IO.puts("Step #{step.name}: #{inspect(step.outputs)}")
  end

  answer_step = Enum.find(row.result.steps, &(&1.name == "answer"))
  {:ok, prepared} = Predictor.prepare(optimized.answer, answer_step.inputs, target)
  IO.puts("\nOptimized answer prompt:")

  for message <- prepared.context.messages do
    IO.puts("\n[#{message.role}]\n" <> Enum.map_join(message.content, "", & &1.text))
  end

  provenance =
    Parameters.provenance(source: "offline QA example", report: report, models: [target: target])

  {:ok, artifact} = Parameters.dump(optimized, provenance: provenance)
  {:ok, json} = Parameters.encode(artifact)
  path = Path.join(System.tmp_dir!(), "tune_offline_#{name}.json")
  File.write!(path, json)

  {:ok, decoded} = Parameters.decode(File.read!(path))
  {:ok, loaded} = Parameters.apply(GroundedQA.new(), decoded)
  [test_row] = testset
  {:ok, result} = Tune.run(loaded, test_row.inputs, model: target, max_model_calls: 2)
  IO.puts("\nArtifact: #{path}")
  IO.puts("Reload matches optimized program: #{loaded == optimized}")
  IO.puts("Reloaded output: #{inspect(result.output)}")
end
