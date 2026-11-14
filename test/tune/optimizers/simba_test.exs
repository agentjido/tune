defmodule Tune.Optimizers.SIMBATest do
  use ExUnit.Case, async: true

  alias Tune
  alias Tune.Adapter
  alias Tune.Optimizers.SIMBA
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

  defp rows(texts), do: Enum.map(texts, &%{inputs: %{ticket: &1}, labels: %{label: "billing"}})

  defp metric(example, result),
    do: if(result.output["label"] == example.labels["label"], do: 1.0, else: 0.0)

  defp proposal(text \\ "Always answer billing."),
    do: Transport.respond_with(fn _ -> Transport.chat(feedback: text) end)

  defp optimize(target, opts, extra \\ []) do
    Tune.optimize(
      classifier(),
      optimizer:
        {SIMBA, Keyword.merge([bsz: 3, num_candidates: 2, max_steps: 2, num_final: 2], opts)},
      trainset: Keyword.get(extra, :train, rows(["easy one", "easy two", "hard case"])),
      valset: rows(["val easy", "val hard"]),
      metric: &metric/2,
      model: config(target),
      proposal: config(Keyword.get(extra, :proposal, proposal())),
      max_model_calls: Keyword.get(extra, :max_model_calls, 300),
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
    assert report.best.selection_score == 1.0
    assert hd(report.candidates).label == "baseline"
    assert hd(report.candidates).selection_score == 0.5
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

    [step] = report.notes.steps
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

    assert Enum.all?(report.notes.steps, &(&1.created == []))
    assert [%{label: "baseline", eligible?: false}] = report.candidates
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
    assert ra.notes.steps == rb.notes.steps
  end
end
