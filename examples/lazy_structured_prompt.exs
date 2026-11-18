# Run with: MIX_ENV=test mix run examples/lazy_structured_prompt.exs
# Req.Test supplies every reply. No external provider is contacted.

defmodule Tune.Examples.LazyStructuredPrompt do
  @moduledoc false

  alias Tune.Adapter.Chat
  alias Tune.Examples.GroundedQA
  alias Tune.ModelConfig
  alias Tune.Predictor
  alias Tune.TestSupport.QAWorld
  alias Tune.TestSupport.Transport

  def run do
    unless Code.ensure_loaded?(QAWorld) do
      raise "Run this example with MIX_ENV=test to load the offline reply helpers."
    end

    train =
      QAWorld.rows([
        {"Where is the Eiffel Tower?", "eiffel-tower", "Paris"},
        {"Who wrote Pride and Prejudice?", "pride-and-prejudice", "Jane Austen"}
      ])

    validation =
      QAWorld.rows([{"Which gas do plants absorb?", "plants", "carbon dioxide"}])

    test =
      QAWorld.rows([
        {"What is the largest ocean?", "ocean", "Pacific"},
        {"What is the capital of Japan?", "japan", "Tokyo"},
        {"What is the closest star?", "star", "Sun"}
      ])

    {:ok, target} = target_model()
    {:ok, teacher} = teacher_model()

    answer_score = fn example, output ->
      if output["answer"] == example.expected["answer"], do: 1.0, else: 0.0
    end

    citation_score = fn example, output ->
      if output["sources"] == example.expected["sources"], do: 1.0, else: 0.0
    end

    pipeline =
      Tune.new(GroundedQA.new(), model: target, teacher: teacher)
      |> Tune.data(train: train, validation: validation, test: test)
      |> Tune.score(:answer, answer_score, argument: :output, range: {0.0, 1.0})
      |> Tune.score(:citations, citation_score, argument: :output, range: {0.0, 1.0})
      |> Tune.select(weighted: [answer: 0.8, citations: 0.2])
      |> Tune.search(:bootstrap_few_shot_random_search,
        accept_score: 1.0,
        num_candidate_programs: 1,
        max_bootstrapped_demos: 1,
        max_labeled_demos: 0
      )
      |> Tune.limit(model_calls: 64)

    {:ok, winner} = Tune.tune(pipeline)
    {:ok, comparison} = Tune.compare(pipeline, winner, split: :test)
    answer = comparison.metrics.answer

    IO.puts("Test answer accuracy: #{answer.baseline_mean} -> #{answer.challenger_mean}")

    IO.puts(
      "Answer rows: #{answer.counts.improved} improved, #{answer.counts.regressed} regressed"
    )

    IO.puts(
      "Model calls: #{comparison.baseline.calls.target} -> #{comparison.challenger.calls.target}"
    )

    print_answer_prompt(winner.value, comparison.challenger, target)
  end

  defp target_model do
    stub =
      QAWorld.stub(
        quality: fn _prompt, answer, body ->
          if QAWorld.demos?(body) != (answer == "Sun"), do: answer, else: "unsure"
        end
      )

    ModelConfig.new(
      model: Transport.model(),
      adapter: Chat,
      request_options: Transport.request_options(stub)
    )
  end

  defp teacher_model do
    ModelConfig.new(
      model: Transport.model(),
      adapter: Chat,
      request_options: Transport.request_options(QAWorld.stub())
    )
  end

  defp print_answer_prompt(optimized, evaluated, target) do
    [observation | _] = evaluated.observations
    answer_step = Enum.find(observation.prediction.steps, &(&1.name == "answer"))
    {:ok, prepared} = Predictor.prepare(optimized.answer, answer_step.inputs, target)

    IO.puts("\nOptimized structured prompt:")

    for message <- prepared.context.messages do
      body = Enum.map_join(message.content, "", & &1.text)
      IO.puts("\n[#{message.role}]\n#{body}")
    end
  end
end

Tune.Examples.LazyStructuredPrompt.run()
