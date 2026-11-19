defmodule Tune.Contracts.ComparisonTest do
  use ExUnit.Case, async: true

  alias Tune.Examples.Support.GroundedQA
  alias Tune.Examples.Support.QAWorld
  alias Tune.Examples.Support.Transport
  alias Tune.Result

  test "resolves a limited split once and pairs the same ordered cases in both directions" do
    owner = self()

    study =
      Tune.new(1, run: fn target, value -> target * value end)
      |> Tune.data(
        test: fn ->
          send(owner, :read_test)
          [%{id: "fast", input: -1}, %{id: "slow", input: 3}, %{id: "tie", input: 0}, :extra]
        end
      )
      |> Tune.score(:quality, & &1)
      |> Tune.score(:cost, & &1, direction: :minimize)
      |> Tune.limit(cases: 3)

    assert {:ok, report} = Tune.compare(study, %Result{value: 2}, split: :test)
    assert_received :read_test
    refute_received :read_test
    assert report.complete?
    assert report.case_ids == ["fast", "slow", "tie"]
    assert Enum.map(report.baseline.observations, & &1.id) == report.case_ids
    assert Enum.map(report.challenger.observations, & &1.id) == report.case_ids
    assert report.rows["fast"].metrics.quality.status == :regressed
    assert report.rows["fast"].metrics.cost.status == :improved
    assert report.rows["slow"].metrics.quality.status == :improved
    assert report.rows["slow"].metrics.cost.status == :regressed
    assert report.rows["tie"].metrics.cost.status == :tied
    assert report.metrics.cost.counts == %{improved: 1, regressed: 1, tied: 1}
  end

  test "returns partial evidence when the baseline uses the shared call budget" do
    stub = Transport.script([Transport.chat(answer: "yes"), Transport.chat(answer: "yes")])

    {:ok, target} =
      Tune.Predictor.new(
        signature: [inputs: [question: Zoi.string()], outputs: [answer: Zoi.string()]]
      )

    study =
      Tune.new(target,
        model: [
          model: Map.put(Transport.model(), :id, "requested-model-alias"),
          adapter: Tune.Adapter.Chat,
          request_options: Transport.request_options(stub)
        ]
      )
      |> Tune.data(
        test: [%{id: "a", input: %{question: "A?"}}, %{id: "b", input: %{question: "B?"}}]
      )
      |> Tune.score(:answer, fn output -> if output["answer"] == "yes", do: 1, else: 0 end)
      |> Tune.score(:steps, fn _case, prediction -> length(prediction.steps) end,
        argument: :prediction
      )
      |> Tune.limit(model_calls: 2)

    assert {:ok, report} = Tune.compare(study, %Result{value: target}, split: :test)
    refute report.complete?
    assert report.baseline.complete?
    assert report.baseline.calls == %{target: 2}
    assert report.baseline.summaries.steps.mean == 1
    assert report.baseline.usage.total == 30

    assert report.baseline.metadata.successful_models == [
             %{role: :target, model: "openai:gpt-4-turbo"}
           ]

    assert report.challenger.calls == %{}
    assert report.challenger.stop_reason == :model_call_limit

    assert report.rows["a"].metrics.answer == %{
             baseline: 1,
             challenger: nil,
             delta: nil,
             status: :unpaired
           }

    assert length(Transport.requests(stub)) == 2
  end

  test "keeps baseline evidence when the shared deadline stops the winner" do
    owner = self()

    run = fn
      :original, value ->
        value

      :winner, _value ->
        send(owner, {:winner_worker, self()})
        Process.sleep(:infinity)
    end

    study =
      Tune.new(:original, run: run)
      |> Tune.data(test: [%{id: "row", input: 5}])
      |> Tune.score(:value, & &1)
      |> Tune.limit(deadline: 300)

    assert {:ok, report} = Tune.compare(study, %Result{value: :winner}, split: :test)
    assert report.baseline.summaries.value.mean == 5
    assert report.rows["row"].baseline.status == :ok
    assert report.challenger.stop_reason == :deadline
    assert report.rows["row"].challenger.status == :interrupted
    assert report.rows["row"].challenger.error.value == :deadline
    assert report.rows["row"].metrics.value.status == :unpaired
    refute report.complete?
    assert_received {:winner_worker, worker}
    refute Process.alive?(worker)
  end

  test "reuses unspent reservations within a concurrent comparison" do
    stub = Transport.script(List.duplicate(Transport.chat(answer: "yes"), 6))

    {:ok, target} =
      Tune.Predictor.new(
        signature: [inputs: [question: Zoi.string()], outputs: [answer: Zoi.string()]]
      )

    study =
      Tune.new(target,
        model: [
          model: Transport.model(),
          adapter: Tune.Adapter.Chat,
          request_options: Transport.request_options(stub)
        ]
      )
      |> Tune.data(test: Enum.map(1..3, &%{input: %{question: "Question #{&1}?"}}))
      |> Tune.score(:answer, fn output -> if output["answer"] == "yes", do: 1, else: 0 end)
      |> Tune.limit(concurrency: 4, model_calls: 6, row_calls: 4)

    assert {:ok, report} = Tune.compare(study, %Result{value: target}, split: :test)
    assert report.complete?
    assert report.baseline.calls == %{target: 3}
    assert report.challenger.calls == %{target: 3}
    assert report.metrics.answer.counts == %{tied: 3}
    assert length(Transport.requests(stub)) == 6
  end

  test "concurrency does not turn unspent reservations into row call limits" do
    target = GroundedQA.new()

    rows =
      QAWorld.rows([{"What is Alpha?", "alpha", "first"}, {"What is Beta?", "beta", "second"}])

    for row_limits <- [[], [row_calls: 3]] do
      stub = QAWorld.stub()

      study =
        Tune.new(target,
          model: [
            model: Transport.model(),
            adapter: Tune.Adapter.Chat,
            request_options: Transport.request_options(stub)
          ]
        )
        |> Tune.data(test: rows)
        |> Tune.score(:answer, &QAWorld.metric/2)
        |> Tune.limit([concurrency: 2, model_calls: 8] ++ row_limits)

      assert {:ok, report} = Tune.compare(study, %Result{value: target}, split: :test)
      assert report.complete?, "comparison did not complete with #{inspect(row_limits)}"
      assert report.baseline.calls == %{target: 4}
      assert report.challenger.calls == %{target: 4}
      assert report.metrics.answer.counts == %{tied: 2}
      assert length(Transport.requests(stub)) == 8
    end
  end

  test "does not start the winner after the baseline loses call accounting" do
    owner = self()

    run = fn
      :original, :quick ->
        5

      :original, :slow ->
        Process.sleep(:infinity)

      :winner, value ->
        send(owner, {:winner_started, value})
        1
    end

    study =
      Tune.new(:original, run: run)
      |> Tune.data(test: [%{id: "quick", input: :quick}, %{id: "slow", input: :slow}])
      |> Tune.score(:value, & &1)
      |> Tune.limit(model_calls: 5, row_calls: 1, row_timeout: 200)

    assert {:ok, report} = Tune.compare(study, %Result{value: :winner}, split: :test)
    assert report.baseline.stop_reason == :lost_accounting
    assert report.baseline.calls == %{target: 1}
    assert report.rows["quick"].baseline.scores == %{value: 5}
    assert report.rows["slow"].baseline.metadata.calls_upper_bound?
    assert report.challenger.stop_reason == :lost_accounting
    assert Enum.map(report.challenger.observations, & &1.status) == [:skipped, :skipped]
    assert report.challenger.calls == %{}
    refute report.complete?
    refute_received {:winner_started, _}
  end

  test "an expired comparison leaves the dataset factory unopened" do
    owner = self()

    study =
      Tune.new(:original, run: fn _, _ -> flunk("a stopped comparison cannot run a target") end)
      |> Tune.data(
        test: fn ->
          send(owner, :opened_dataset)
          [1]
        end
      )
      |> Tune.score(:value, & &1)
      |> Tune.limit(deadline: 0)

    assert {:ok, report} = Tune.compare(study, %Result{value: :winner}, split: :test)
    refute_received :opened_dataset
    assert report.case_ids == []
    assert report.baseline.stop_reason == :deadline
    assert report.challenger.stop_reason == :deadline
    refute report.complete?
  end

  test "rejects missing splits and invalid IDs before calling either target" do
    study =
      Tune.new(1, run: fn _, _ -> flunk("no runner should start") end)
      |> Tune.score(:score, fn _ -> 0 end)

    winner = %Result{value: 2}
    assert {:error, %Tune.Error.Invalid.Option{option: :split}} = Tune.compare(study, winner, [])

    assert {:error, %Tune.Error.Invalid.Option{option: :test}} =
             Tune.compare(study, winner, split: :test)

    for ids <- [["duplicate", "duplicate"], ["  "], [nil], [1], [<<255>>]] do
      rows = Enum.map(ids, &%{id: &1, input: 0})

      assert {:error, %Tune.Error.Invalid.Definition{}} =
               study |> Tune.data(test: rows) |> Tune.compare(winner, split: :test)
    end

    assert {:error, %Tune.Error.Invalid.Definition{message: message}} =
             study
             |> Tune.data(test: [%{id: "row", input: 1, metadata: []}])
             |> Tune.compare(winner, split: :test)

    assert message =~ "metadata"
  end

  test "ordinary evaluation keeps coercing map IDs" do
    assert {:ok, report} =
             Tune.new(:identity, run: fn _, value -> value end)
             |> Tune.data(test: [%{id: 12, input: 1}, %{id: nil, input: 2}])
             |> Tune.score(:score, & &1)
             |> Tune.evaluate()

    assert Enum.map(report.observations, & &1.id) == ["12", ""]
  end
end
