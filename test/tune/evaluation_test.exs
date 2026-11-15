defmodule Tune.EvaluationTest do
  use ExUnit.Case, async: true

  alias Tune
  alias Tune.Adapter
  alias Tune.Error
  alias Tune.Evaluation
  alias Tune.Predictor
  alias Tune.TestSupport.Transport

  setup do
    {:ok, predictor} =
      Predictor.new(signature: [inputs: [text: Zoi.string()], outputs: [label: Zoi.string()]])

    %{predictor: predictor}
  end

  defp model(stub),
    do: [
      model: Transport.model(),
      adapter: Adapter.Chat,
      request_options: Transport.request_options(stub)
    ]

  defp echo_stub do
    Transport.respond_with(fn body ->
      [_, text] = Regex.run(~r/\[\[ ## text ## \]\]\n(.*?)\n/s, Transport.last_user_text(body))

      case text do
        "fail" -> {:text, "no markers"}
        other -> Transport.chat(label: "label-" <> other)
      end
    end)
  end

  defp rows(texts),
    do: Enum.map(texts, &%{input: %{text: &1}, expected: %{label: "label-" <> &1}})

  defp exact(example, result),
    do: if(result.output["label"] == example.expected["label"], do: 1, else: 0)

  defp evaluate(program, rows, opts) do
    pipeline =
      program
      |> Tune.new(model: Keyword.fetch!(opts, :model))
      |> Tune.data(test: rows)

    pipeline =
      case Keyword.fetch(opts, :metric) do
        {:ok, metric} ->
          Tune.score(pipeline, :objective, metric,
            failure_score: Keyword.get(opts, :failure_score)
          )

        :error ->
          pipeline
      end

    limits =
      []
      |> put_limit(:model_calls, Keyword.get(opts, :max_model_calls))
      |> put_limit(:row_calls, Keyword.get(opts, :max_row_calls))
      |> put_limit(:row_timeout, Keyword.get(opts, :row_timeout))
      |> put_limit(:concurrency, Keyword.get(opts, :concurrency))

    pipeline |> Tune.limit(limits) |> Tune.evaluate()
  end

  defp put_limit(limits, _key, nil), do: limits
  defp put_limit(limits, key, value), do: Keyword.put(limits, key, value)

  defp total_calls(evaluation), do: evaluation.calls |> Map.values() |> Enum.sum()

  defmodule FailedJudgeScore do
    @behaviour Tune.Score
    defstruct []

    @impl true
    def score(_score, _case, _output) do
      {:error, :judge_failed,
       %{
         calls: %{judge: 1},
         judge_calls: [
           %{usage: %{input_tokens: 10, output_tokens: 5, total_tokens: 15}}
         ]
       }}
    end
  end

  test "failed scores retain judge calls and token use" do
    assert {:ok, evaluation} =
             Tune.new(%{}, run: fn _target, input -> input end)
             |> Tune.data(test: [1])
             |> Tune.score(:judge, %FailedJudgeScore{})
             |> Tune.limit(model_calls: 1)
             |> Tune.evaluate()

    assert evaluation.calls == %{judge: 1}
    assert evaluation.usage == %{input: 10, output: 5, total: 15}
    assert [%{status: :error}] = evaluation.observations
  end

  test "scores every row with arbitrary finite numbers", ctx do
    metric = fn example, _result -> if example.input["text"] == "a", do: -2.5, else: 10 end

    assert {:ok, %Evaluation{} = eval} =
             evaluate(ctx.predictor, rows(["a", "b"]),
               model: model(echo_stub()),
               metric: metric
             )

    assert Enum.map(eval.observations, & &1.scores.objective) == [-2.5, 10]
    assert Evaluation.mean(eval) == 3.75
    assert eval.selected_score == 3.75
    assert Evaluation.coverage(eval) == 1.0
    assert eval.eligible? and eval.complete?
    assert total_calls(eval) == 2
  end

  test "score shorthand and score/feedback maps are equivalent", ctx do
    stub = echo_stub()

    {:ok, plain} =
      evaluate(ctx.predictor, rows(["a"]),
        model: model(stub),
        metric: fn _, _ -> 0.5 end
      )

    {:ok, rich} =
      evaluate(ctx.predictor, rows(["a"]),
        model: model(stub),
        metric: fn _, _ -> %{score: 0.5, feedback: "ok"} end
      )

    assert plain.selected_score == rich.selected_score
    assert [%{feedback: %{objective: nil}}] = plain.observations
    assert [%{feedback: %{objective: "ok"}}] = rich.observations
  end

  test "raised and invalid metric results are row errors", ctx do
    stub = echo_stub()

    for metric <- [
          fn _, _ -> raise "boom" end,
          fn _, _ -> :great end,
          fn _, _ -> %{score: 1, feedback: 2} end
        ] do
      assert {:ok, eval} =
               evaluate(ctx.predictor, rows(["a"]),
                 model: model(stub),
                 metric: metric
               )

      assert [%{status: :error, error: %Error.Execution.Callback{}}] = eval.observations
      refute eval.eligible?
    end
  end

  test "failed rows make a candidate ineligible without an explicit failure score", ctx do
    assert {:ok, eval} =
             evaluate(ctx.predictor, rows(["a", "fail", "b"]),
               model: model(echo_stub()),
               metric: &exact/2
             )

    assert [%{status: :ok}, %{status: :error, id: "1", error: error}, %{status: :ok}] =
             eval.observations

    assert %Error.Execution.Failed{cause: %Error.Output.Parse{}} = error
    assert Evaluation.mean(eval) == 1.0
    assert Evaluation.coverage(eval) == 2 / 3
    assert eval.complete?
    refute eval.eligible?
    assert eval.selected_score == nil
  end

  test "an explicit failure score is included in the mean and keeps the error visible", ctx do
    assert {:ok, eval} =
             evaluate(ctx.predictor, rows(["a", "fail", "b", "c"]),
               model: model(echo_stub()),
               metric: &exact/2,
               failure_score: -1
             )

    assert eval.eligible?
    assert eval.selected_score == (1 + 1 + 1 - 1) / 4
    assert Evaluation.mean(eval) == 1.0
    assert [%{status: :error}] = Enum.filter(eval.observations, &(&1.status == :error))
  end

  test "labels never reach the program", ctx do
    stub = echo_stub()
    data = [%{input: %{text: "a"}, expected: %{label: "SECRET-LABEL"}}]

    assert {:ok, _eval} =
             evaluate(ctx.predictor, data, model: model(stub), metric: &exact/2)

    [body] = Transport.requests(stub)
    refute Transport.prompt_text(body) =~ "SECRET-LABEL"
  end

  test "setup errors are not rows", ctx do
    assert {:error, %Error.Invalid.Definition{}} =
             evaluate(ctx.predictor, [],
               model: model(echo_stub()),
               metric: &exact/2
             )

    assert {:error, %Error.Invalid.Definition{}} =
             evaluate(ctx.predictor, [%{input: %{text: "a", label: "x"}}],
               model: model(echo_stub()),
               metric: &exact/2
             )

    assert {:error, %Error.Invalid.Option{option: :scores}} =
             evaluate(ctx.predictor, rows(["a"]), model: model(echo_stub()))

    assert_raise ArgumentError, fn ->
      evaluate(ctx.predictor, rows(["a"]),
        model: model(echo_stub()),
        metric: &exact/2,
        failure_score: :low
      )
    end
  end

  test "a budget interruption leaves the evaluation incomplete, not penalized", ctx do
    stub = echo_stub()

    assert {:ok, eval} =
             evaluate(ctx.predictor, rows(["a", "b", "c"]),
               model: model(stub),
               metric: &exact/2,
               failure_score: 0,
               max_model_calls: 2
             )

    assert Enum.map(eval.observations, & &1.status) == [:ok, :ok, :skipped]
    refute eval.complete?
    refute eval.eligible?
    assert eval.stop_reason == :model_call_limit
    assert total_calls(eval) == 2
    assert length(Transport.requests(stub)) == 2
  end

  defp warm_up(predictor) do
    stub = echo_stub()
    {:ok, _} = Tune.Runtime.run(predictor, %{text: "warm"}, model: model(stub))
    Transport.requests(stub)
  end

  test "a killed worker reserves its allowance and stops further calls under a limit", ctx do
    warm_up(ctx.predictor)
    stub = echo_stub()

    slow = fn example, _result ->
      if example.input["text"] == "a", do: Process.sleep(3_000), else: 1
    end

    assert {:ok, eval} =
             evaluate(ctx.predictor, rows(["a", "b"]),
               model: model(stub),
               metric: slow,
               row_timeout: 500,
               max_model_calls: 5
             )

    assert [timed_out] = eval.observations
    assert timed_out.status == :error
    assert timed_out.calls == %{target: 5}
    assert timed_out.metadata.calls_upper_bound?

    assert eval.stop_reason == :lost_accounting
    assert length(Transport.requests(stub)) == 1
  end

  test "without a limit a timed-out row is an error and evaluation continues", ctx do
    warm_up(ctx.predictor)

    slow = fn example, _result ->
      if example.input["text"] == "a", do: Process.sleep(3_000), else: 1
    end

    assert {:ok, eval} =
             evaluate(ctx.predictor, rows(["a", "b"]),
               model: model(echo_stub()),
               metric: slow,
               row_timeout: 500
             )

    assert [%{status: :error}, %{status: :ok}] = eval.observations
    assert eval.stop_reason == :completed
  end

  test "concurrent rows keep their identities and outputs", ctx do
    texts = Enum.map(1..8, &"t#{&1}")

    assert {:ok, eval} =
             evaluate(ctx.predictor, rows(texts),
               model: model(echo_stub()),
               metric: &exact/2,
               concurrency: 4
             )

    assert Enum.map(eval.observations, & &1.id) == Enum.map(0..7, &Integer.to_string/1)

    assert Enum.map(eval.observations, & &1.output["label"]) ==
             Enum.map(texts, &("label-" <> &1))

    assert eval.selected_score == 1.0
  end

  test "concurrent rows reserve per-row allowances from the total", ctx do
    stub = echo_stub()

    assert {:ok, eval} =
             evaluate(ctx.predictor, rows(["a", "b", "c", "d"]),
               model: model(stub),
               metric: &exact/2,
               concurrency: 4,
               max_model_calls: 3,
               max_row_calls: 1
             )

    assert Enum.count(eval.observations, &(&1.status == :ok)) == 3
    assert Enum.count(eval.observations, &(&1.status == :skipped)) == 1
    assert eval.stop_reason == :model_call_limit
    assert length(Transport.requests(stub)) == 3
  end

  defmodule Crashing do
    @behaviour Tune.Program
    defstruct []
    @impl true
    def signature(_),
      do:
        elem(
          Tune.Signature.new(
            inputs: [text: Zoi.string()],
            outputs: [label: Zoi.string()]
          ),
          1
        )

    @impl true
    def parameters(_), do: %{}
    @impl true
    def put_parameters(program, _), do: program
    @impl true
    def call(_program, _inputs, _execution), do: raise("application bug")
  end

  test "a crashing row worker is a row error and other rows still run" do
    assert {:ok, eval} =
             evaluate(%Crashing{}, rows(["a", "b"]),
               model: model(echo_stub()),
               metric: &exact/2
             )

    assert [%{status: :error}, %{status: :error}] = eval.observations
    assert eval.complete?
    refute eval.eligible?
  end
end
