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

  defp rows(texts), do: Enum.map(texts, &%{inputs: %{text: &1}, labels: %{label: "label-" <> &1}})

  defp exact(example, result),
    do: if(result.output["label"] == example.labels["label"], do: 1, else: 0)

  test "scores every row with arbitrary finite numbers", ctx do
    metric = fn example, _result -> if example.inputs["text"] == "a", do: -2.5, else: 10 end

    assert {:ok, %Evaluation{} = eval} =
             Tune.evaluate(ctx.predictor, rows(["a", "b"]),
               model: model(echo_stub()),
               metric: metric
             )

    assert Enum.map(eval.rows, & &1.score) == [-2.5, 10]
    assert eval.mean == 3.75
    assert eval.selection_score == 3.75
    assert eval.coverage == 1.0
    assert eval.eligible? and eval.complete?
    assert eval.calls == 2
  end

  test "score shorthand and score/feedback maps are equivalent", ctx do
    stub = echo_stub()

    {:ok, plain} =
      Tune.evaluate(ctx.predictor, rows(["a"]), model: model(stub), metric: fn _, _ -> 0.5 end)

    {:ok, rich} =
      Tune.evaluate(ctx.predictor, rows(["a"]),
        model: model(stub),
        metric: fn _, _ -> %{score: 0.5, feedback: "ok"} end
      )

    assert plain.selection_score == rich.selection_score
    assert [%{feedback: nil}] = plain.rows
    assert [%{feedback: "ok"}] = rich.rows
  end

  test "raised and invalid metric results are row errors", ctx do
    stub = echo_stub()

    for metric <- [
          fn _, _ -> raise "boom" end,
          fn _, _ -> :great end,
          fn _, _ -> %{score: 1, feedback: 2} end
        ] do
      assert {:ok, eval} =
               Tune.evaluate(ctx.predictor, rows(["a"]), model: model(stub), metric: metric)

      assert [%{status: :error, error: %Error.Execution.Callback{}}] = eval.rows
      refute eval.eligible?
    end
  end

  test "failed rows make a candidate ineligible without an explicit failure score", ctx do
    assert {:ok, eval} =
             Tune.evaluate(ctx.predictor, rows(["a", "fail", "b"]),
               model: model(echo_stub()),
               metric: &exact/2
             )

    assert [%{status: :ok}, %{status: :error, id: "1", error: error}, %{status: :ok}] = eval.rows
    assert %Error.Execution.Failed{cause: %Error.Output.Parse{}} = error
    assert eval.mean == 1.0
    assert eval.coverage == 2 / 3
    assert eval.complete?
    refute eval.eligible?
    assert eval.selection_score == nil
  end

  test "an explicit failure score is included in the mean and keeps the error visible", ctx do
    assert {:ok, eval} =
             Tune.evaluate(ctx.predictor, rows(["a", "fail", "b", "c"]),
               model: model(echo_stub()),
               metric: &exact/2,
               failure_score: -1
             )

    assert eval.eligible?
    assert eval.selection_score == (1 + 1 + 1 - 1) / 4
    assert eval.mean == 1.0
    assert [%{status: :error}] = Enum.filter(eval.rows, &(&1.status == :error))
  end

  test "labels never reach the program", ctx do
    stub = echo_stub()
    data = [%{inputs: %{text: "a"}, labels: %{label: "SECRET-LABEL"}}]

    assert {:ok, _eval} =
             Tune.evaluate(ctx.predictor, data, model: model(stub), metric: &exact/2)

    [body] = Transport.requests(stub)
    refute Transport.prompt_text(body) =~ "SECRET-LABEL"
  end

  test "setup errors are not rows", ctx do
    assert {:error, %Error.Invalid.Definition{}} =
             Tune.evaluate(ctx.predictor, [], model: model(echo_stub()), metric: &exact/2)

    assert {:error, %Error.Invalid.Definition{}} =
             Tune.evaluate(ctx.predictor, [%{inputs: %{text: "a", label: "x"}}],
               model: model(echo_stub()),
               metric: &exact/2
             )

    assert {:error, %Error.Invalid.Option{option: :metric}} =
             Tune.evaluate(ctx.predictor, rows(["a"]), model: model(echo_stub()))

    assert {:error, %Error.Invalid.Option{option: :failure_score}} =
             Tune.evaluate(ctx.predictor, rows(["a"]),
               model: model(echo_stub()),
               metric: &exact/2,
               failure_score: :low
             )
  end

  test "a budget interruption leaves the evaluation incomplete, not penalized", ctx do
    stub = echo_stub()

    assert {:ok, eval} =
             Tune.evaluate(ctx.predictor, rows(["a", "b", "c"]),
               model: model(stub),
               metric: &exact/2,
               failure_score: 0,
               max_model_calls: 2
             )

    assert Enum.map(eval.rows, & &1.status) == [:ok, :ok, :skipped]
    refute eval.complete?
    refute eval.eligible?
    assert eval.stop_reason == :budget_exhausted
    assert eval.calls == 2
    assert length(Transport.requests(stub)) == 2
  end

  defp warm_up(predictor) do
    stub = echo_stub()
    {:ok, _} = Tune.run(predictor, %{text: "warm"}, model: model(stub))
    Transport.requests(stub)
  end

  test "a killed worker reserves its allowance and stops further calls under a limit", ctx do
    warm_up(ctx.predictor)
    stub = echo_stub()

    slow = fn example, _result ->
      if example.inputs["text"] == "a", do: Process.sleep(3_000), else: 1
    end

    assert {:ok, eval} =
             Tune.evaluate(ctx.predictor, rows(["a", "b"]),
               model: model(stub),
               metric: slow,
               row_timeout: 500,
               max_model_calls: 5
             )

    assert [%{status: :error, calls: 5, calls_upper_bound?: true}, %{status: :skipped}] =
             eval.rows

    assert eval.stop_reason == :lost_accounting
    assert length(Transport.requests(stub)) == 1
  end

  test "without a limit a timed-out row is an error and evaluation continues", ctx do
    warm_up(ctx.predictor)

    slow = fn example, _result ->
      if example.inputs["text"] == "a", do: Process.sleep(3_000), else: 1
    end

    assert {:ok, eval} =
             Tune.evaluate(ctx.predictor, rows(["a", "b"]),
               model: model(echo_stub()),
               metric: slow,
               row_timeout: 500
             )

    assert [%{status: :error, calls_upper_bound?: true}, %{status: :ok}] = eval.rows
    assert eval.stop_reason == :completed
  end

  test "concurrent rows keep their identities and outputs", ctx do
    texts = Enum.map(1..8, &"t#{&1}")

    assert {:ok, eval} =
             Tune.evaluate(ctx.predictor, rows(texts),
               model: model(echo_stub()),
               metric: &exact/2,
               concurrency: 4
             )

    assert Enum.map(eval.rows, & &1.id) == Enum.map(0..7, &Integer.to_string/1)
    assert Enum.map(eval.rows, & &1.output["label"]) == Enum.map(texts, &("label-" <> &1))
    assert eval.selection_score == 1.0
  end

  test "concurrent rows reserve per-row allowances from the total", ctx do
    stub = echo_stub()

    assert {:ok, eval} =
             Tune.evaluate(ctx.predictor, rows(["a", "b", "c", "d"]),
               model: model(stub),
               metric: &exact/2,
               concurrency: 4,
               max_model_calls: 3,
               max_row_calls: 1
             )

    assert Enum.count(eval.rows, &(&1.status == :ok)) == 3
    assert Enum.count(eval.rows, &(&1.status == :skipped)) == 1
    assert eval.stop_reason == :budget_exhausted
    assert length(Transport.requests(stub)) == 3
  end

  defmodule Crashing do
    @behaviour Tune
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
             Tune.evaluate(%Crashing{}, rows(["a", "b"]),
               model: model(echo_stub()),
               metric: &exact/2
             )

    assert [%{status: :error}, %{status: :error}] = eval.rows
    assert eval.complete?
    refute eval.eligible?
  end
end
