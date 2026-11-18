defmodule Tune.Optimizers.SIMBATest do
  use ExUnit.Case, async: true

  alias Tune
  alias Tune.Adapter
  alias Tune.Examples.Support.Transport
  alias Tune.Optimizers.SIMBA
  alias Tune.Predictor

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

  defp rows(texts), do: Enum.map(texts, &%{input: %{ticket: &1}, expected: %{label: "billing"}})

  defp metric(example, output),
    do: if(output["label"] == example.expected["label"], do: 1.0, else: 0.0)

  defp proposal(text \\ "Always answer billing."),
    do: Transport.respond_with(fn _ -> Transport.chat(feedback: text) end)

  defp optimize(target, opts, extra \\ []) do
    Tune.TestSupport.Search.run(
      classifier(),
      search:
        {SIMBA, Keyword.merge([bsz: 3, num_candidates: 2, max_steps: 2, num_final: 2], opts)},
      train: Keyword.get(extra, :train, rows(["easy one", "easy two", "hard case"])),
      validation: rows(["val easy", "val hard"]),
      metric: &metric/2,
      model: config(target),
      proposal: config(Keyword.get(extra, :proposal, proposal())),
      model_calls: Keyword.get(extra, :model_calls, 300),
      seed: Keyword.get(extra, :seed, 1)
    )
  end

  defp demo?(body), do: Enum.any?(body["messages"], &(&1["role"] == "assistant"))

  test "a successful trajectory becomes a demo that fixes weak rows" do
    target =
      Transport.respond_with(fn body ->
        user = Transport.last_user_text(body)

        if user =~ "easy" or demo?(body),
          do: Transport.chat(label: "billing"),
          else: Transport.chat(label: "bug")
      end)

    assert {:ok, best, report} = optimize(target, strategies: [:append_a_demo])
    assert [demo | _] = best.demos
    assert demo.inputs["ticket"] =~ "easy"
    assert report.best.evaluation.selected_score == 1.0
    assert hd(report.history).metadata.label == "baseline"
    assert hd(report.history).evaluation.selected_score == 0.5
  end

  test "variable behavior is targeted first and its own success becomes the demo" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    target =
      Transport.respond_with(fn body ->
        user = Transport.last_user_text(body)

        cond do
          demo?(body) ->
            Transport.chat(label: "billing")

          user =~ "flaky" ->
            n = Agent.get_and_update(counter, &{&1, &1 + 1})
            Transport.chat(label: if(rem(n, 2) == 0, do: "billing", else: "bug"))

          true ->
            Transport.chat(label: "bug")
        end
      end)

    assert {:ok, _best, report} =
             optimize(target, [strategies: [:append_a_demo], max_steps: 1, num_candidates: 2],
               train: rows(["steady", "flaky case", "other"])
             )

    [step] = report.metadata.notes.steps
    assert hd(step.targeted).gap == 1.0
    assert hd(step.targeted).row == "1"
    assert hd(step.created).row == "1"
    assert step.batch |> Enum.sort() == ["0", "1", "2"]
  end

  test "the rule path appends contrastive advice to an instruction" do
    target =
      Transport.respond_with(fn body ->
        prompt = Transport.prompt_text(body)
        user = Transport.last_user_text(body)

        if user =~ "easy" or prompt =~ "Always answer billing",
          do: Transport.chat(label: "billing"),
          else: Transport.chat(label: "bug")
      end)

    proposal = proposal()

    assert {:ok, best, _report} =
             optimize(target, [strategies: [:append_a_rule]], proposal: proposal)

    assert best.signature.instructions == "Label it.\n\nAlways answer billing."

    [request | _] = Transport.requests(proposal)
    assert Transport.prompt_text(request) =~ "score: 1.0"
    assert Transport.prompt_text(request) =~ "score: 0.0"
  end

  test "failed trajectories never produce updates" do
    target = Transport.respond_with(fn _ -> {:text, "unparseable"} end)

    assert {:error, %Tune.Error.Optimization.Failed{report: report}} =
             optimize(target, [], train: rows(["a", "b", "c"]))

    assert Enum.all?(report.metadata.notes.steps, &(&1.created == []))
    assert [baseline] = report.history
    assert baseline.metadata.label == "baseline"
    refute baseline.evaluation.eligible?
  end

  test "the same seed gives the same search" do
    rule = fn body ->
      user = Transport.last_user_text(body)

      if user =~ "easy" or demo?(body),
        do: Transport.chat(label: "billing"),
        else: Transport.chat(label: "bug")
    end

    {:ok, a, ra} = optimize(Transport.respond_with(rule), [], seed: 9)
    {:ok, b, rb} = optimize(Transport.respond_with(rule), [], seed: 9)
    assert a == b
    assert ra.metadata.notes.steps == rb.metadata.notes.steps
  end
end
