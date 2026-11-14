defmodule Tune.Optimizers.InferRulesTest do
  use ExUnit.Case, async: true

  alias Tune
  alias Tune.Adapter
  alias Tune.Optimizers.InferRules
  alias Tune.Predictor
  alias Tune.TestSupport.Transport

  defp config(stub),
    do: [
      model: Transport.model(),
      adapter: Adapter.Chat,
      request_options: Transport.request_options(stub)
    ]

  defp classifier do
    {:ok, predictor} =
      Predictor.new(
        signature: [
          instructions: "Label it.",
          inputs: [ticket: Zoi.string()],
          outputs: [label: Zoi.string()]
        ]
      )

    predictor
  end

  defp train,
    do: for(i <- 1..3, do: %{inputs: %{ticket: "ticket #{i}"}, labels: %{label: "billing"}})

  defp val,
    do: [
      %{inputs: %{ticket: "val 1"}, labels: %{label: "billing"}},
      %{inputs: %{ticket: "val 2"}, labels: %{label: "SECRET"}}
    ]

  defp metric(example, result),
    do: if(result.output["label"] == example.labels["label"], do: 1.0, else: 0.0)

  defp teacher, do: Transport.respond_with(fn _ -> Transport.chat(label: "billing") end)

  defp target(rule) do
    Transport.respond_with(fn body ->
      prompt = Transport.prompt_text(body)
      demo? = Enum.any?(body["messages"], &(&1["role"] == "assistant"))
      Transport.chat(label: rule.(prompt, demo?))
    end)
  end

  defp run(target, rules, opts \\ []) do
    proposal = Transport.respond_with(fn _ -> Transport.chat(rules: rules) end)

    result =
      Tune.optimize(classifier(),
        optimizer:
          {InferRules,
           Keyword.merge(
             [
               accept_score: 1.0,
               num_candidates: 1,
               max_labeled_demos: 0,
               max_bootstrapped_demos: 2
             ],
             opts
           )},
        trainset: train(),
        valset: val(),
        metric: &metric/2,
        model: config(target),
        teacher: config(teacher()),
        proposal: config(proposal),
        max_model_calls: 100
      )

    {result, proposal}
  end

  test "derived rules appear in the inspectable instruction when they help" do
    target =
      target(fn prompt, _demo? ->
        if prompt =~ "Always say billing", do: "billing", else: "bug"
      end)

    {{:ok, best, report}, proposal} = run(target, ["Always say billing.", "Be brief."])

    assert best.signature.instructions ==
             "Label it.\n\nPlease adhere to the following rules when making your prediction:\n1. Always say billing.\n2. Be brief."

    assert length(best.demos) == 2
    assert Enum.map(report.candidates, & &1.label) == ["original", "bootstrapped", "rules_1"]
    assert report.best.label == "rules_1"

    for body <- Transport.requests(proposal) do
      text = Transport.prompt_text(body)
      assert text =~ "ticket 1"
      refute text =~ "SECRET"
      refute text =~ "val 1"
    end
  end

  test "a worse rule set is rejected and the bootstrapped baseline wins" do
    target =
      target(fn prompt, demo? ->
        cond do
          prompt =~ "Never say billing" -> "bug"
          demo? -> "billing"
          true -> "bug"
        end
      end)

    {{:ok, best, report}, _} = run(target, ["Never say billing."])
    assert best.signature.instructions == "Label it."
    assert report.best.label == "bootstrapped"
  end

  test "the original program remains selectable" do
    target = target(fn _prompt, demo? -> if demo?, do: "bug", else: "billing" end)
    {{:ok, best, report}, _} = run(target, ["Anything."])
    assert best == classifier()
    assert report.best.label == "original"
  end
end
