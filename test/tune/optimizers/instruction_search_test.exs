defmodule Tune.Optimizers.InstructionSearchTest do
  use ExUnit.Case, async: true

  alias Tune
  alias Tune.Adapter
  alias Tune.Error
  alias Tune.Examples.GroundedQA
  alias Tune.Optimizers.COPRO
  alias Tune.Optimizers.SignatureOptimizer
  alias Tune.TestSupport.QAWorld
  alias Tune.TestSupport.Transport

  defp config(stub),
    do: [
      model: Transport.model(),
      adapter: Adapter.Chat,
      request_options: Transport.request_options(stub)
    ]

  defp train,
    do: QAWorld.rows([{"What is Alpha?", "alpha", "first"}, {"What is Beta?", "beta", "second"}])

  defp val,
    do:
      QAWorld.rows([{"What is Gamma?", "gamma", "third"}, {"What is Delta?", "delta", "fourth"}])

  defp target do
    QAWorld.stub(
      quality: fn prompt, answer ->
        if prompt =~ "Cite the passage", do: answer, else: "unsure"
      end
    )
  end

  defp proposer(fun) do
    Transport.respond_with(fn body ->
      prompt = Transport.prompt_text(body)
      Transport.chat(instructions: fun.(prompt))
    end)
  end

  defp base(stub, proposal) do
    [
      trainset: train(),
      valset: val(),
      metric: &QAWorld.metric/2,
      model: config(stub),
      proposal: config(proposal),
      max_model_calls: 200
    ]
  end

  test "evaluates several proposals per predictor and keeps the improvement" do
    proposal =
      proposer(fn prompt ->
        if prompt =~ "Outputs: `answer`",
          do: ["Answer briefly.", "Cite the passage id and answer from the facts.", "Guess."],
          else: ["Select facts.", "Select every fact."]
      end)

    assert {:ok, best, report} =
             Tune.TestSupport.Search.run(
               GroundedQA.new(),
               [optimizer: {COPRO, breadth: 3, depth: 1}] ++ base(target(), proposal)
             )

    assert best.answer.signature.instructions == "Cite the passage id and answer from the facts."
    assert best.extract.signature.instructions == GroundedQA.new().extract.signature.instructions
    assert report.best.evaluation.selected_score == 1.0
    assert hd(report.history).metadata.label == "baseline"
    assert hd(report.history).evaluation.selected_score == 0.0
    assert length(report.history) == 1 + 3 + 2
    assert report.calls.proposal == 2
  end

  test "later rounds see earlier attempts with their validation scores" do
    proposal =
      proposer(fn prompt ->
        if prompt =~ "Outputs: `answer`" and prompt =~ "score",
          do: ["Cite the passage id and answer."],
          else: ["Answer quickly."]
      end)

    assert {:ok, best, _report} =
             Tune.TestSupport.Search.run(
               GroundedQA.new(),
               [optimizer: {COPRO, breadth: 1, depth: 2, predictors: ["answer"]}] ++
                 base(target(), proposal)
             )

    assert best.answer.signature.instructions == "Cite the passage id and answer."
    [first, second] = Transport.requests(proposal)
    assert Transport.prompt_text(first) =~ "None."
    assert Transport.prompt_text(second) =~ "score 0.0: Answer quickly."
  end

  test "proposals see training evidence and never validation labels" do
    proposal = proposer(fn _ -> ["Answer."] end)

    {:ok, _best, _report} =
      Tune.TestSupport.Search.run(
        GroundedQA.new(),
        [optimizer: {COPRO, breadth: 1, depth: 1}] ++ base(target(), proposal)
      )

    for body <- Transport.requests(proposal) do
      text = Transport.prompt_text(body)
      assert text =~ "first"
      refute text =~ "third"
      refute text =~ "fourth"
    end
  end

  test "invalid proposals leave the baseline in place" do
    proposal = Transport.respond_with(fn _ -> {:text, "I would suggest being clearer."} end)

    assert {:ok, best, report} =
             Tune.TestSupport.Search.run(
               GroundedQA.new(),
               [optimizer: {COPRO, breadth: 2, depth: 1}] ++ base(target(), proposal)
             )

    assert best == GroundedQA.new()
    assert [baseline] = report.history
    assert baseline.metadata.label == "baseline"
    assert report.calls.proposal == 2
  end

  test "SignatureOptimizer changes only the named predictor" do
    proposal = proposer(fn _ -> ["Cite the passage id, then select or answer."] end)

    assert {:ok, best, report} =
             Tune.TestSupport.Search.run(
               GroundedQA.new(),
               [optimizer: {SignatureOptimizer, predictor: "extract", breadth: 1, depth: 1}] ++
                 base(target(), proposal)
             )

    assert best.answer == GroundedQA.new().answer

    assert Enum.all?(
             Transport.requests(proposal),
             &(Transport.prompt_text(&1) =~ "Outputs: `facts`")
           )

    assert Enum.all?(tl(report.history), &(&1.metadata.predictor == "extract"))
  end

  test "a limit keeps the best complete incumbent" do
    proposal = proposer(fn _ -> ["Cite the passage id and answer.", "Other."] end)

    assert {:ok, best, report} =
             Tune.TestSupport.Search.run(
               GroundedQA.new(),
               [optimizer: {COPRO, breadth: 2, depth: 2, predictors: ["answer"]}] ++
                 Keyword.put(base(target(), proposal), :max_model_calls, 4 + 1 + 4 + 2)
             )

    refute report.complete?
    assert report.stop_reason == :budget_exhausted
    assert best.answer.signature.instructions == "Cite the passage id and answer."
  end

  test "configuration is explicit" do
    assert {:error, %Error.Invalid.Option{option: :predictor}} =
             Tune.TestSupport.Search.run(
               GroundedQA.new(),
               [optimizer: SignatureOptimizer] ++ base(:unused, :unused)
             )

    assert {:error, %Error.Invalid.Option{option: :proposal}} =
             Tune.TestSupport.Search.run(
               GroundedQA.new(),
               [optimizer: COPRO] ++ Keyword.delete(base(:unused, :unused), :proposal)
             )

    assert {:error, %Error.Optimization.Failed{cause: %Error.Invalid.Option{option: :predictors}}} =
             Tune.TestSupport.Search.run(
               GroundedQA.new(),
               [optimizer: {COPRO, predictors: ["missing"]}] ++ base(:unused, :unused)
             )
  end
end
