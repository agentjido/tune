defmodule Tune.Examples.BootstrapQAComparison do
  @moduledoc "Compare a learned QA program with its baseline on held-out cases."

  alias Tune.Examples.Support.{GroundedQA, Offline, QAWorld}
  alias Tune.ModelConfig
  alias Tune.Predictor

  def run do
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
    teacher = Offline.model(QAWorld.stub())

    answer_score = fn example, output ->
      if output["answer"] == example.expected["answer"], do: 1.0, else: 0.0
    end

    citation_score = fn example, output ->
      if output["sources"] == example.expected["sources"], do: 1.0, else: 0.0
    end

    study =
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
      |> Tune.limit(model_calls: 64, seed: 0)

    {:ok, winner} = Tune.tune(study)
    {:ok, comparison} = Tune.compare(study, winner, split: :test)
    {:ok, prompt} = answer_prompt(winner.value, comparison.challenger, target)
    %{comparison: comparison, prompt: prompt}
  end

  defp target_model do
    stub =
      QAWorld.stub(
        quality: fn _prompt, answer, body ->
          if QAWorld.demos?(body) != (answer == "Sun"), do: answer, else: "unsure"
        end
      )

    ModelConfig.new(Offline.model(stub))
  end

  defp answer_prompt(optimized, evaluated, target) do
    [observation | _] = evaluated.observations
    answer_step = Enum.find(observation.prediction.steps, &(&1.name == "answer"))
    Predictor.prepare(optimized.answer, answer_step.inputs, target)
  end
end
