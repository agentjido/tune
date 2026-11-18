defmodule Tune.Examples.BootstrapQA do
  @moduledoc "Learn demonstrations from complete grounded QA trajectories."

  alias Tune.Examples.Support.{GroundedQA, Offline}
  alias Tune.Examples.Support.QAWorld

  def run(options \\ []) do
    train =
      QAWorld.rows([
        {"Which city is home to the Eiffel Tower?", "tower", "Paris"},
        {"Who wrote Pride and Prejudice?", "novel", "Jane Austen"},
        {"Which gas do plants absorb?", "plants", "carbon dioxide"}
      ])

    test = QAWorld.rows([{"What is the largest ocean?", "ocean", "Pacific"}])
    teacher = QAWorld.stub(Keyword.get(options, :teacher_options, []))

    study =
      Tune.new(GroundedQA.new(),
        model: Offline.model(QAWorld.stub()),
        teacher: Offline.model(teacher)
      )
      |> Tune.data(train: train, test: test)
      |> Tune.score(:answer, &QAWorld.metric/2)
      |> Tune.search(:bootstrap_few_shot, accept_score: 1.0, max_bootstrapped_demos: 3)
      |> Tune.limit(model_calls: 24)

    {:ok, winner} = Tune.tune(study)
    {:ok, holdout} = Tune.compare(study, winner, split: :test)
    %{winner: winner, holdout: holdout, teacher: teacher}
  end
end
