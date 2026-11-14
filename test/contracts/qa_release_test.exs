defmodule Tune.Contracts.QAReleaseTest do
  use ExUnit.Case, async: true

  alias Tune.Adapter
  alias Tune.Examples.Comparison
  alias Tune.Examples.GroundedQA
  alias Tune.Optimizers.BootstrapFewShotWithRandomSearch
  alias Tune.TestSupport.QAWorld
  alias Tune.TestSupport.Transport

  @moduledoc """
  Offline reference proof: the grounded QA example compared before and after
  optimization for each fixed target configuration, through all three prompt
  formats, with prompt inspection, parse success, token use, and reload.
  All model replies are scripted through Req.Test behind the public ReqLLM API.
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

  test "baseline and optimized QA for each fixed target configuration" do
    targets = [
      {"chat", Adapter.Chat, []},
      {"json", Adapter.JSON, [mode: :text]},
      {"xml", Adapter.XML, []}
    ]

    configured =
      Enum.map(targets, fn {name, adapter, options} -> {name, target(adapter, options)} end)

    teacher_stub = QAWorld.stub()

    rows =
      Comparison.run(
        &GroundedQA.new/0,
        Enum.map(configured, fn {name, {config, _stub}} -> {name, config} end),
        optimizer:
          {BootstrapFewShotWithRandomSearch,
           accept_score: 1.0,
           num_candidate_programs: 1,
           max_bootstrapped_demos: 1,
           max_labeled_demos: 0},
        trainset:
          QAWorld.rows([
            {"What is Alpha?", "alpha", "first"},
            {"What is Beta?", "beta", "second"}
          ]),
        valset: QAWorld.rows([{"What is Gamma?", "gamma", "third"}]),
        testset:
          QAWorld.rows([
            {"What is Delta?", "delta", "fourth"},
            {"What is Omega?", "omega", "last"}
          ]),
        metric: &QAWorld.metric/2,
        teacher: [
          model: Transport.model(),
          adapter: Adapter.Chat,
          request_options: Transport.request_options(teacher_stub)
        ],
        max_model_calls: 100
      )

    assert length(rows) == 3

    for row <- rows do
      assert row.baseline.selection_score == 0.0
      assert row.baseline.parse_success == 1.0
      assert row.optimized.selection_score == 1.0
      assert row.optimized.eligible?
      assert row.optimized.parse_success == 1.0
      assert row.calls > 0
      assert row.tokens > 0
      assert row.reloaded?
      assert row.model == "openai:gpt-4-turbo"
      assert row.report.calls.teacher > 0
      assert Map.keys(row.prompts) |> Enum.sort() == ["answer", "extract"]
    end

    [chat, json, xml] = rows
    assert prompt(chat, "extract") =~ "[[ ## context ## ]]"
    assert prompt(json, "answer") =~ "Outputs will be a JSON object"
    assert prompt(xml, "extract") =~ "<context>"
    assert Enum.any?(chat.prompts["answer"], &match?({:assistant, _}, &1))

    table = Comparison.table(rows)

    assert table =~
             "chat | openai:gpt-4-turbo | Tune.Adapter.Chat | 0.000 | 1.000 | true | 100% -> 100%"

    assert table =~ "xml | openai:gpt-4-turbo | Tune.Adapter.XML"
  end

  defp prompt(row, name), do: Enum.map_join(row.prompts[name], "\n", &elem(&1, 1))
end
