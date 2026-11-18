defmodule Tune.Examples.BootstrapQATest do
  @moduledoc "Example tests for learning demonstrations from teacher responses."
  use ExUnit.Case, async: true

  @moduletag :example

  alias Tune.Examples.BootstrapQA
  alias Tune.Examples.BootstrapQAComparison
  alias Tune.Examples.Support.Transport

  test "bootstraps both stages and scores a separate holdout" do
    %{winner: winner, holdout: holdout, teacher: teacher} = BootstrapQA.run()

    assert winner.metadata.notes.bootstrapped == %{"answer" => 3, "extract" => 3}
    assert winner.calls == %{teacher: 6}
    assert holdout.challenger.summaries.answer.mean == 1.0

    for body <- Transport.requests(teacher) do
      current = Transport.last_user_text(body)
      question = Tune.Examples.Support.Offline.field(current, "question")
      user_messages = Enum.filter(body["messages"], &(&1["role"] == "user"))
      assert Enum.count(user_messages, &String.contains?(&1["content"], question)) == 1
    end
  end

  test "a failed answer contributes no demonstrations to either stage" do
    opts = [teacher_options: [overrides: %{"Who wrote Pride and Prejudice?" => :fail_answer}]]
    %{winner: winner} = BootstrapQA.run(opts)

    assert winner.metadata.notes.bootstrapped == %{"answer" => 2, "extract" => 2}

    for predictor <- [winner.value.extract, winner.value.answer], demo <- predictor.demos do
      refute demo.inputs["question"] =~ "Pride and Prejudice"
    end
  end

  test "the paired holdout shows improvements and a regression" do
    %{comparison: comparison, prompt: prompt} = BootstrapQAComparison.run()

    assert comparison.metrics.answer.counts == %{improved: 2, regressed: 1}
    assert comparison.metrics.citations.delta == 0.0

    assert comparison.baseline.calls.target == 6
    assert comparison.challenger.calls.target == 6
    assert Enum.any?(prompt.context.messages, &(&1.role == :assistant))
  end
end
