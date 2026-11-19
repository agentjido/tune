defmodule Tune.Contracts.SavedEvaluationTest do
  use ExUnit.Case, async: true

  alias Tune.Evaluation
  alias Tune.Examples.Support.Transport
  alias Tune.Scores.ContextPrecision
  alias Tune.Scores.Faithfulness

  @fixture Path.expand("../fixtures/evaluation/saved_responses.jsonl", __DIR__)

  test "replays saved answers asynchronously and counts the failed judge attempt" do
    stub =
      Transport.script([
        {:tool, ~s({"statements":[{"text":"Paris is in France."}]})},
        {:tool, ~s({"supported":true,"reasoning":"The context states it."})},
        {:http_error, 422, %{"error" => %{"message" => "scripted judge failure"}}}
      ])

    {:ok, faithfulness} = Faithfulness.new(judge_options(stub))
    {:ok, precision} = ContextPrecision.new(judge_options(stub))
    supervisor = start_supervised!({Task.Supervisor, []})
    owner = self()

    task =
      fn -> File.stream!(@fixture) |> Stream.map(&JSON.decode!/1) end
      |> Tune.replay(on_progress: &send(owner, &1))
      |> Tune.score(:faithfulness, faithfulness)
      |> Tune.score(:precision, precision)
      |> Tune.limit(model_calls: 3)
      |> then(&Evaluation.start(supervisor, &1))

    assert {:ok, result} = Task.await(task, 10_000)
    assert result.selected_score == nil
    assert result.stop_reason == :model_call_limit
    assert result.calls == %{judge: 3}
    assert length(Transport.requests(stub)) == 3
    assert result.summaries.faithfulness.mean == 1.0
    assert result.summaries.precision.count == 0

    assert [
             %{
               id: "paris",
               status: :error,
               scores: %{faithfulness: 1.0},
               score_errors: %{precision: _}
             },
             %{id: "rome", status: :skipped}
           ] = result.observations

    assert_received %{event: :rows_evaluated, rows: [%{id: "paris", status: :error}]}
  end

  test "a judge cannot reuse the budget charged to a bootstrap teacher" do
    teacher = Transport.script([Transport.chat(response: "Paris is in France.")])
    judge = Transport.script([])
    {:ok, faithfulness} = Faithfulness.new(judge_options(judge))

    {:ok, predictor} =
      Tune.Predictor.new(
        signature: [
          inputs: [retrieved_contexts: Zoi.array(Zoi.string())],
          outputs: [response: Zoi.string()]
        ]
      )

    model = [
      model: Transport.model(),
      adapter: Tune.Adapter.Chat,
      request_options: Transport.request_options(teacher)
    ]

    assert {:error, %Tune.Error.Optimization.Failed{report: report}} =
             predictor
             |> Tune.new(model: model, teacher: model)
             |> Tune.data(train: [%{input: %{retrieved_contexts: ["Paris is in France."]}}])
             |> Tune.score(:faithfulness, faithfulness)
             |> Tune.search(:bootstrap_few_shot, accept_score: 1.0)
             |> Tune.limit(model_calls: 1)
             |> Tune.tune()

    assert report.calls == %{teacher: 1}
    assert length(Transport.requests(teacher)) == 1
    assert Transport.requests(judge) == []
  end

  test "compares the baseline and loaded winner on one held-out snapshot" do
    owner = self()

    pipeline =
      Tune.new(%{value: 0}, run: fn target, factor -> target.value * factor end)
      |> Tune.data(
        validation: [1],
        test: fn ->
          send(owner, :read_test_split)
          [10, 20]
        end
      )
      |> Tune.vary(value: 0..1)
      |> Tune.score(:value, & &1)
      |> Tune.search(:genetic, initial_population: [%{value: 0}, %{value: 1}], generations: 0)
      |> Tune.limit(evaluations: 2)

    assert {:ok, result} = Tune.tune(pipeline)
    refute_received :read_test_split
    assert {:ok, artifact} = Tune.dump(result)

    assert {:error, %Tune.Error.Invalid.Option{option: :split}} =
             Tune.compare(pipeline, artifact, [])

    refute_received :read_test_split

    assert {:ok, %Tune.Comparison{split: :test} = comparison} =
             Tune.compare(pipeline, artifact, split: :test)

    assert comparison.baseline.selected_score == 0
    assert comparison.challenger.selected_score == 15
    assert comparison.metrics.value.counts == %{improved: 2}
    assert_received :read_test_split
    refute_received :read_test_split
  end

  test "replays input and output directly with two independent metrics and no target calls" do
    study =
      [%{"id" => "saved", "input" => "question", "output" => "answer", "expected" => "answer"}]
      |> Tune.replay()
      |> Tune.score(:exact, fn row, output ->
        if row.input == "question" and row.expected == output, do: 1, else: 0
      end)
      |> Tune.score(:broken, fn _row, _output -> {:error, :failed_metric} end)
      |> Tune.limit(model_calls: 0)

    assert {:ok, report} = Tune.evaluate(study)
    assert map_size(report.calls) == 0
    assert report.selected_score == nil
    assert report.summaries.exact.mean == 1
    assert report.summaries.broken.count == 0

    assert [%{id: "saved", scores: %{exact: 1}, score_errors: %{broken: :failed_metric}}] =
             report.observations
  end

  test "validates streamed rows lazily and preserves arbitrary saved terms" do
    owner = self()
    input = make_ref()
    output = fn -> :saved end

    rows = [
      %{"id" => 21, "input" => input, "output" => output, "expected" => {:answer, input}},
      %{id: "no-output", input: nil},
      %{id: "no-input", output: nil},
      %{id: "nulls", input: nil, output: nil},
      %{id: {:invalid, :id}, input: false, output: true},
      %{input: :past_limit, output: :unused}
    ]

    study =
      Tune.replay(fn ->
        send(owner, :opened_rows)
        Stream.map(rows, & &1)
      end)
      |> Tune.score(:preserved, fn row, value ->
        send(owner, {:scored, row.id, row.input, value, row.expected})
        1
      end)
      |> Tune.limit(cases: 5)

    refute_received :opened_rows
    assert {:ok, report} = Tune.evaluate(study)
    assert_received :opened_rows
    refute_received :opened_rows
    assert_received {:scored, "21", ^input, ^output, {:answer, ^input}}
    assert_received {:scored, "nulls", nil, nil, nil}
    refute_received {:scored, _, _, _, _}

    assert [%{status: :ok}, missing_output, missing_input, %{status: :ok}, invalid_id] =
             report.observations

    assert %{id: "no-output", status: :error, error: %{message: message}} = missing_output
    assert message =~ "output"
    assert %{id: "no-input", status: :error, error: %{message: message}} = missing_input
    assert message =~ "input"
    assert %{id: "4", status: :error, error: %{message: message}} = invalid_id
    assert message =~ "id"
    assert report.summaries.preserved.count == 2
    assert report.calls == %{}
  end

  test "returns a setup error when a replay factory fails or returns invalid data" do
    sources = [fn -> raise "saved file is unavailable" end, fn -> :unavailable end]

    for source <- sources do
      assert {:error, %Tune.Error.Invalid.Dataset{split: :test}} =
               source
               |> Tune.replay()
               |> Tune.score(:value, fn _row, _output -> flunk("scored invalid data") end)
               |> Tune.evaluate()
    end
  end

  defp judge_options(stub) do
    [
      model: Transport.model(),
      request_options:
        Transport.request_options(stub, openai_structured_output_mode: :tool_strict)
    ]
  end
end
