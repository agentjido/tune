defmodule Tune.Optimizers.MIPROv2Test do
  use ExUnit.Case, async: true

  alias Tune
  alias Tune.Adapter
  alias Tune.Examples.Support.Transport
  alias Tune.Optimizers.MIPROv2
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

  defp train(n),
    do: for(i <- 1..n, do: %{input: %{ticket: "ticket #{i}"}, expected: %{label: "billing"}})

  defp val(n),
    do: for(i <- 1..n, do: %{input: %{ticket: "val #{i}"}, expected: %{label: "billing"}})

  defp metric(example, output),
    do: if(output["label"] == example.expected["label"], do: 1.0, else: 0.0)

  defp target do
    Transport.respond_with(fn body ->
      prompt = Transport.prompt_text(body)
      user = Transport.last_user_text(body)
      demo? = Enum.any?(body["messages"], &(&1["role"] == "assistant"))

      cond do
        prompt =~ "Memorize" and user =~ "\nticket " -> Transport.chat(label: "billing")
        prompt =~ "Be exact" and demo? -> Transport.chat(label: "billing")
        true -> Transport.chat(label: "bug")
      end
    end)
  end

  defp teacher, do: Transport.respond_with(fn _ -> Transport.chat(label: "billing") end)

  defp proposer do
    Transport.respond_with(fn _ ->
      Transport.chat(instructions: ["Memorize the answers.", "Be exact."])
    end)
  end

  defp optimize(opts) do
    Tune.TestSupport.Search.run(
      classifier(),
      search:
        {MIPROv2,
         Keyword.merge(
           [
             accept_score: 1.0,
             num_candidates: 3,
             num_trials: 10,
             minibatch_size: 2,
             minibatch_full_eval_steps: 3,
             n_startup: 3,
             max_labeled_demos: 0,
             max_bootstrapped_demos: 1
           ],
           opts
         )},
      train: train(4),
      validation: val(3),
      metric: &metric/2,
      model: config(target()),
      teacher: config(teacher()),
      proposal: config(proposer()),
      model_calls: 300,
      seed: 5
    )
  end

  test "finds the instruction and example set that validate together" do
    assert {:ok, best, report} = optimize([])

    assert best.signature.instructions == "Be exact."
    assert best.demos != []
    assert report.best.evaluation.selected_score == 1.0
    assert report.complete?
    assert Map.keys(report.calls) |> Enum.sort() == [:proposal, :target, :teacher]

    assert report.metadata.notes.instructions["root"] == [
             "Label it.",
             "Memorize the answers.",
             "Be exact."
           ]
  end

  test "minibatch winners must pass full validation to be returned" do
    assert {:ok, best, report} = optimize([])

    memorize =
      Enum.filter(report.metadata.notes.trials, fn trial ->
        trial.choice["root.instruction"] == 1
      end)

    assert memorize != []
    assert Enum.all?(memorize, &(&1.score == 1.0))
    refute best.signature.instructions == "Memorize the answers."

    for candidate <- report.history do
      assert candidate.evaluation.complete?
    end
  end

  test "modeled suggestions concentrate on high-scoring choices after startup" do
    assert {:ok, _best, report} = optimize(num_trials: 14)
    after_startup = Enum.drop(report.metadata.notes.trials, 3)
    good = Enum.count(after_startup, &(&1.score == 1.0))
    assert good > length(after_startup) / 2
  end

  test "teacher, proposal, and target calls share one ceiling" do
    assert {:ok, _best, report} = optimize_limited(25)
    refute report.complete?
    assert report.stop_reason == :budget_exhausted
    assert report.calls |> Map.values() |> Enum.sum() <= 25
  end

  defp optimize_limited(limit) do
    Tune.TestSupport.Search.run(classifier(),
      search:
        {MIPROv2,
         accept_score: 1.0,
         num_candidates: 3,
         num_trials: 10,
         minibatch_size: 2,
         max_labeled_demos: 0},
      train: train(4),
      validation: val(3),
      metric: &metric/2,
      model: config(target()),
      teacher: config(teacher()),
      proposal: config(proposer()),
      model_calls: limit
    )
  end
end
