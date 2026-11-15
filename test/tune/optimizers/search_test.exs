defmodule Tune.Optimizers.SearchTest do
  use ExUnit.Case, async: true

  alias Tune
  alias Tune.Adapter
  alias Tune.Error
  alias Tune.Optimizers.BootstrapFewShotWithOptuna
  alias Tune.Optimizers.BootstrapFewShotWithRandomSearch
  alias Tune.Optimizers.TPE
  alias Tune.Predictor
  alias Tune.Search.Program.Context
  alias Tune.TestSupport.Transport

  defp config(stub),
    do: [
      model: Transport.model(),
      adapter: Adapter.Chat,
      request_options: Transport.request_options(stub)
    ]

  defp classifier do
    {:ok, predictor} =
      Predictor.new(signature: [inputs: [ticket: Zoi.string()], outputs: [label: Zoi.string()]])

    predictor
  end

  defp train(n),
    do: for(i <- 1..n, do: %{input: %{ticket: "ticket #{i}"}, expected: %{label: "billing"}})

  defp val(n),
    do: for(i <- 1..n, do: %{input: %{ticket: "val #{i}"}, expected: %{label: "billing"}})

  defp teacher, do: Transport.respond_with(fn _ -> Transport.chat(label: "billing") end)

  defp target(rule) do
    Transport.respond_with(fn body ->
      prompt = Transport.prompt_text(body)
      user = Transport.last_user_text(body)

      case rule.(prompt, user) do
        :fail -> {:text, "unparseable"}
        label -> Transport.chat(label: label)
      end
    end)
  end

  defp metric(example, result),
    do: if(result.output["label"] == example.expected["label"], do: 1.0, else: 0.0)

  defp has_demo?(prompt, ticket), do: String.contains?(prompt, "[[ ## ticket ## ]]\n#{ticket}\n")

  describe "TPE" do
    test "uses uniform suggestions during startup" do
      ctx = Context.new(optimizer: nil, run_options: [], seed: 1)
      tpe = TPE.new(%{"a" => 4}, n_startup: 3)
      {choices, _ctx} = Enum.map_reduce(1..40, ctx, fn _, ctx -> TPE.suggest(tpe, [], ctx) end)
      assert choices |> Enum.map(& &1["a"]) |> Enum.uniq() |> Enum.sort() == [0, 1, 2, 3]
    end

    test "after startup, suggestions follow the good/bad density ratio" do
      ctx = Context.new(optimizer: nil, run_options: [], seed: 1)
      tpe = TPE.new(%{"a" => 4, "b" => 3}, n_startup: 4, gamma: 0.05)

      observations =
        for a <- 0..3, b <- 0..2 do
          {%{"a" => a, "b" => b}, if(a == 2 and b == 1, do: 1.0, else: 0.0)}
        end

      {l, g} = TPE.densities(tpe, observations)["a"]
      assert Enum.at(l, 2) / Enum.at(g, 2) == Enum.max(Enum.zip_with(l, g, &(&1 / &2)))

      {choices, _ctx} =
        Enum.map_reduce(1..20, ctx, fn _, ctx -> TPE.suggest(tpe, observations, ctx) end)

      assert Enum.count(choices, &(&1 == %{"a" => 2, "b" => 1})) >= 18
    end
  end

  describe "BootstrapFewShotWithRandomSearch" do
    test "keeps the best fully validated candidate and records every candidate" do
      stub =
        target(fn prompt, _user ->
          if has_demo?(prompt, "ticket 1"), do: "billing", else: "bug"
        end)

      assert {:ok, best, report} =
               Tune.TestSupport.Search.run(classifier(),
                 optimizer:
                   {BootstrapFewShotWithRandomSearch,
                    accept_score: 1.0, num_candidate_programs: 2, max_labeled_demos: 0},
                 trainset: train(3),
                 valset: val(2),
                 metric: &metric/2,
                 model: config(stub),
                 teacher: config(teacher()),
                 max_model_calls: 100
               )

      assert report.complete?

      assert Enum.map(report.history, & &1.metadata.label) == [
               "zero_shot",
               "labeled",
               "bootstrap",
               "bootstrap_0",
               "bootstrap_1"
             ]

      assert hd(report.history).evaluation.selected_score == 0.0
      assert report.best.evaluation.selected_score == 1.0
      assert report.best.metadata.label == "bootstrap"
      assert Enum.any?(best.demos, &(&1.inputs["ticket"] == "ticket 1"))
    end

    test "ties keep the earlier candidate" do
      stub = target(fn _prompt, _user -> "billing" end)

      assert {:ok, best, report} =
               Tune.TestSupport.Search.run(classifier(),
                 optimizer:
                   {BootstrapFewShotWithRandomSearch,
                    accept_score: 1.0, num_candidate_programs: 1},
                 trainset: train(2),
                 valset: val(2),
                 metric: &metric/2,
                 model: config(stub),
                 teacher: config(teacher()),
                 max_model_calls: 100
               )

      assert report.best.metadata.label == "zero_shot"
      assert best.demos == []
    end

    test "a candidate with a failed validation row is ineligible" do
      stub =
        target(fn prompt, user ->
          cond do
            not has_demo?(prompt, "ticket 1") and user =~ "val 2" -> :fail
            not has_demo?(prompt, "ticket 1") -> "billing"
            true -> "bug"
          end
        end)

      assert {:ok, _best, report} =
               Tune.TestSupport.Search.run(classifier(),
                 optimizer:
                   {BootstrapFewShotWithRandomSearch,
                    accept_score: 1.0, num_candidate_programs: 0, max_labeled_demos: 0},
                 trainset: train(2),
                 valset: val(2),
                 metric: &metric/2,
                 model: config(stub),
                 teacher: config(teacher()),
                 max_model_calls: 100
               )

      [zero | _] = report.history
      assert Tune.Evaluation.mean(zero.evaluation) == 1.0
      refute zero.evaluation.eligible?
      assert report.best.metadata.label == "bootstrap"
      assert report.best.evaluation.selected_score == 0.0
    end

    test "a limit during evaluation returns the previous complete incumbent" do
      stub = target(fn _prompt, _user -> "billing" end)

      assert {:ok, _best, report} =
               Tune.TestSupport.Search.run(classifier(),
                 optimizer:
                   {BootstrapFewShotWithRandomSearch,
                    accept_score: 1.0, num_candidate_programs: 3},
                 trainset: train(2),
                 valset: val(3),
                 metric: &metric/2,
                 model: config(stub),
                 teacher: config(teacher()),
                 max_model_calls: 4
               )

      refute report.complete?
      assert report.stop_reason == :budget_exhausted
      assert report.best.metadata.label == "zero_shot"

      assert Enum.map(report.history, &{&1.evaluation.complete?, &1.evaluation.eligible?}) == [
               {true, true},
               {false, false}
             ]

      assert report.calls == %{target: 4}
    end

    test "with no complete candidate the error carries the report" do
      assert {:error, %Error.Optimization.Failed{report: report}} =
               Tune.TestSupport.Search.run(classifier(),
                 optimizer: {BootstrapFewShotWithRandomSearch, accept_score: 1.0},
                 trainset: train(2),
                 valset: val(3),
                 metric: &metric/2,
                 model: config(target(fn _, _ -> "billing" end)),
                 teacher: config(teacher()),
                 max_model_calls: 2
               )

      assert report.stop_reason == :budget_exhausted
      assert report.best == nil
      assert length(report.history) == 1
    end

    test "validation data is required and must not overlap training inputs" do
      base = [
        optimizer: {BootstrapFewShotWithRandomSearch, accept_score: 1.0},
        trainset: train(2),
        metric: &metric/2,
        model: config(:unused),
        teacher: config(:unused),
        max_model_calls: 10
      ]

      assert {:error, %Error.Invalid.Option{option: :valset}} =
               Tune.TestSupport.Search.run(classifier(), base)

      assert {:error, %Error.Invalid.Definition{message: message}} =
               Tune.TestSupport.Search.run(
                 classifier(),
                 Keyword.put(base, :valset, [hd(train(1))])
               )

      assert message =~ "same inputs"
    end

    test "the same seed gives the same search" do
      opts = [
        optimizer:
          {BootstrapFewShotWithRandomSearch, accept_score: 1.0, num_candidate_programs: 2},
        trainset: train(5),
        valset: val(2),
        metric: &metric/2,
        teacher: config(teacher()),
        max_model_calls: 200,
        seed: 3
      ]

      rule = fn prompt, _ -> if has_demo?(prompt, "ticket 4"), do: "billing", else: "bug" end

      {:ok, first, r1} =
        Tune.TestSupport.Search.run(classifier(), [model: config(target(rule))] ++ opts)

      {:ok, second, r2} =
        Tune.TestSupport.Search.run(classifier(), [model: config(target(rule))] ++ opts)

      assert first == second

      assert Enum.map(r1.history, & &1.evaluation.selected_score) ==
               Enum.map(r2.history, & &1.evaluation.selected_score)
    end
  end

  describe "BootstrapFewShotWithOptuna" do
    test "modeled suggestions find the example set that validates best" do
      stub =
        target(fn prompt, _user ->
          if has_demo?(prompt, "ticket 5"), do: "billing", else: "bug"
        end)

      assert {:ok, best, report} =
               Tune.TestSupport.Search.run(classifier(),
                 optimizer:
                   {BootstrapFewShotWithOptuna,
                    accept_score: 1.0,
                    max_bootstrapped_demos: 1,
                    max_labeled_demos: 0,
                    num_demo_sets: 6,
                    num_trials: 12,
                    n_startup: 3},
                 trainset: train(6),
                 valset: val(2),
                 metric: &metric/2,
                 model: config(stub),
                 teacher: config(teacher()),
                 max_model_calls: 200,
                 seed: 11
               )

      assert report.complete?
      assert report.best.evaluation.selected_score == 1.0
      assert [%{inputs: %{"ticket" => "ticket 5"}}] = best.demos

      trials = report.metadata.notes.trials
      assert length(trials) == 12
      winning = for {choice, 1.0} <- trials, do: choice
      after_startup = trials |> Enum.drop(3) |> Enum.map(&elem(&1, 0))
      assert Enum.count(after_startup, &(&1 in winning)) > length(after_startup) / 2

      evaluated = Enum.count(report.history)
      assert evaluated < 12
      assert report.calls.target == evaluated * 2
    end
  end
end
