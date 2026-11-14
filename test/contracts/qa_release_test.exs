defmodule Tune.Contracts.QAReleaseTest do
  use ExUnit.Case, async: true

  alias Tune.Adapter
  alias Tune.Artifact
  alias Tune.Examples.GroundedQA
  alias Tune.TestSupport.QAWorld
  alias Tune.TestSupport.Transport

  @moduledoc """
  Offline release proof for the public lazy pipeline.

  It compares a two-step grounded QA program before and after search for each
  prompt format. All replies use Req.Test through the public ReqLLM API.
  """

  defp target(adapter, options) do
    stub =
      QAWorld.stub(
        quality: fn _prompt, answer, body ->
          if QAWorld.demos?(body), do: answer, else: "unsure"
        end
      )

    {[
       model: Transport.model(),
       adapter: adapter,
       adapter_options: options,
       request_options: Transport.request_options(stub)
     ], stub}
  end

  defp teacher do
    stub = QAWorld.stub()

    {[
       model: Transport.model(),
       adapter: Adapter.Chat,
       request_options: Transport.request_options(stub)
     ], stub}
  end

  test "the public pipeline tunes and reloads QA for every prompt format" do
    train =
      QAWorld.rows([
        {"What is Alpha?", "alpha", "first"},
        {"What is Beta?", "beta", "second"}
      ])

    validation = QAWorld.rows([{"What is Gamma?", "gamma", "third"}])

    test =
      QAWorld.rows([
        {"What is Delta?", "delta", "fourth"},
        {"What is Omega?", "omega", "last"}
      ])

    {teacher, _teacher_stub} = teacher()

    for {adapter, options, marker} <- [
          {Adapter.Chat, [], "[[ ## question ## ]]"},
          {Adapter.JSON, [mode: :text], "Outputs will be a JSON object"},
          {Adapter.XML, [], "<question>"}
        ] do
      {target, target_stub} = target(adapter, options)

      pipeline =
        GroundedQA.new()
        |> Tune.new(model: target, teacher: teacher)
        |> Tune.data(train: train, validation: validation)
        |> scores()
        |> Tune.search(:bootstrap_few_shot_random_search,
          accept_score: 1.0,
          num_candidate_programs: 1,
          max_bootstrapped_demos: 1,
          max_labeled_demos: 0
        )
        |> Tune.limit(model_calls: 100)

      assert {:ok, baseline} = evaluate(GroundedQA.new(), target, test)
      assert baseline.selected_score == 0.2

      assert {:ok, result} = Tune.tune(pipeline)
      assert {:ok, optimized} = evaluate(result.value, target, test)
      assert optimized.selected_score == 1.0
      assert optimized.eligible?
      assert result.calls.teacher > 0

      [observation | _] = optimized.observations
      answer_step = Enum.find(observation.prediction.steps, &(&1.name == "answer"))

      assert {:ok, prepared} =
               result.value
               |> Tune.new(model: target)
               |> Tune.preview({"answer", answer_step.inputs})

      prompt = Enum.map_join(prepared.context.messages, "\n", &message_text/1)
      assert prompt =~ marker
      assert Enum.any?(prepared.context.messages, &(&1.role == :assistant))

      assert {:ok, artifact} = Tune.dump(result)
      assert {:ok, json} = Artifact.encode(artifact)
      assert {:ok, decoded} = Artifact.decode(json)
      assert {:ok, loaded} = Tune.load(decoded, GroundedQA.new())
      assert Tune.Program.parameters(loaded) == Tune.Program.parameters(result.value)

      assert Transport.requests(target_stub) != []
    end
  end

  defp scores(pipeline) do
    pipeline
    |> Tune.score(
      :answer,
      fn example, prediction ->
        if prediction.output["answer"] == example.labels["answer"], do: 1.0, else: 0.0
      end,
      range: {0.0, 1.0}
    )
    |> Tune.score(
      :citations,
      fn example, prediction ->
        if prediction.output["sources"] == example.labels["sources"], do: 1.0, else: 0.0
      end,
      range: {0.0, 1.0}
    )
    |> Tune.select(weighted: [answer: 0.8, citations: 0.2])
  end

  defp evaluate(program, target, test) do
    program
    |> Tune.new(model: target)
    |> Tune.data(test: test)
    |> scores()
    |> Tune.limit(model_calls: 8)
    |> Tune.evaluate()
  end

  defp message_text(message), do: Enum.map_join(message.content, "", & &1.text)
end
