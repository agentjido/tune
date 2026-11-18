defmodule Tune.JudgeScoresTest do
  use ExUnit.Case, async: true

  alias Tune.Case
  alias Tune.Examples.Support.Transport
  alias Tune.Scores.ContextPrecision
  alias Tune.Scores.Faithfulness

  defp judge_options(stub) do
    [
      model: Transport.model(),
      request_options:
        Transport.request_options(stub,
          openai_structured_output_mode: :tool_strict
        )
    ]
  end

  test "faithfulness uses structured ReqLLM calls and keeps judge evidence" do
    stub =
      Transport.script([
        {:tool, ~s({"statements":[{"text":"Paris is in France."}]})},
        {:tool, ~s({"supported":true,"reasoning":"The context states it."})}
      ])

    {:ok, score} = Faithfulness.new(judge_options(stub))

    tune_case = %Case{
      id: "faithful",
      input: %{retrieved_contexts: ["Paris is the capital of France."]},
      expected: nil
    }

    assert {:ok, evaluation} =
             Tune.new(%{}, run: fn _target, _input -> %{response: "Paris is in France."} end)
             |> Tune.data(test: [tune_case])
             |> Tune.score(:faithfulness, score, range: {0.0, 1.0})
             |> Tune.evaluate()

    assert evaluation.selected_score == 1.0
    assert evaluation.calls == %{judge: 2}
    [observation] = evaluation.observations
    assert observation.feedback.faithfulness == "1/1 statements supported"
    assert length(observation.metadata.scores.faithfulness.judge_calls) == 2
    assert length(Transport.requests(stub)) == 2
  end

  test "context precision preserves retrieval order" do
    stub =
      Transport.respond_with(fn body ->
        prompt = Transport.prompt_text(body)
        relevant = not String.contains?(prompt, "irrelevant")
        {:tool, JSON.encode!(%{relevant: relevant, reasoning: "scripted"})}
      end)

    {:ok, score} = ContextPrecision.new(judge_options(stub))

    tune_case = %Case{
      id: "precision",
      input: %{
        user_input: "Where is Paris?",
        retrieved_contexts: ["irrelevant", "Paris is in France", "France contains Paris"]
      },
      expected: "Paris is in France"
    }

    assert {:ok, evaluation} =
             Tune.new(%{}, run: fn _target, _input -> :unused end)
             |> Tune.data(test: [tune_case])
             |> Tune.score(:context_precision, score, range: {0.0, 1.0})
             |> Tune.evaluate()

    assert_in_delta evaluation.selected_score, 0.5833, 0.001
    [observation] = evaluation.observations

    assert Enum.map(observation.metadata.scores.context_precision.details.contexts, & &1.relevant) ==
             [false, true, true]

    assert evaluation.calls == %{judge: 3}
  end

  test "generic search with a judge requires a model call limit" do
    stub = Transport.script([])
    {:ok, score} = Faithfulness.new(judge_options(stub))

    tune_case = %Case{
      id: "limit",
      input: %{retrieved_contexts: ["context"]},
      expected: nil
    }

    pipeline =
      Tune.new(%{value: 0}, run: fn _target, _input -> %{response: "answer"} end)
      |> Tune.data(validation: [tune_case])
      |> Tune.vary(value: 0..1)
      |> Tune.score(:faithfulness, score, range: {0.0, 1.0})
      |> Tune.search(:genetic, population_size: 2, generations: 0)
      |> Tune.limit(evaluations: 2)

    assert {:error, %Tune.Error.Invalid.Option{option: :model_calls}} = Tune.tune(pipeline)
    assert Transport.requests(stub) == []
  end
end
