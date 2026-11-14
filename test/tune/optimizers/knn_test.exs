defmodule Tune.Optimizers.KNNTest do
  use ExUnit.Case, async: true

  alias Tune
  alias Tune.Adapter
  alias Tune.Error
  alias Tune.KNN
  alias Tune.Optimizers.KNNFewShot
  alias Tune.Parameters
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
      Predictor.new(signature: [inputs: [ticket: Zoi.string()], outputs: [label: Zoi.string()]])

    predictor
  end

  @pool [
    %{inputs: %{ticket: "refund my card payment"}, labels: %{label: "billing"}},
    %{inputs: %{ticket: "the app crashes on start"}, labels: %{label: "bug"}},
    %{inputs: %{ticket: "invoice payment failed twice"}, labels: %{label: "billing"}}
  ]

  defp echo_teacher do
    Transport.respond_with(fn body ->
      text = Transport.last_user_text(body)
      Transport.chat(label: if(text =~ "crash", do: "bug", else: "billing"))
    end)
  end

  defp knn(opts \\ []) do
    {:ok, program, report} =
      Tune.TestSupport.Search.run(classifier(),
        optimizer: {KNNFewShot, Keyword.merge([k: 1], opts)},
        trainset: @pool,
        model: config(:unused)
      )

    assert report.calls == %{}
    program
  end

  test "construction makes no calls and declares the pool as a parameter" do
    program = knn()
    assert %KNN{} = program
    {:ok, parameters} = Tune.Program.parameters(program)
    assert Map.keys(parameters) |> Enum.sort() == ["knn_pool", "root"]
    assert length(parameters["knn_pool"].value) == 3
  end

  test "different inputs receive demos from their nearest neighbors, and teacher calls are counted" do
    teacher = echo_teacher()
    target = Transport.respond_with(fn _ -> Transport.chat(label: "billing") end)
    opts = [model: config(target), teacher: config(teacher), max_model_calls: 10]

    assert {:ok, crash} = Tune.Runtime.run(knn(), %{ticket: "it crashes when I start it"}, opts)
    assert crash.calls == %{teacher: 1, target: 1}

    assert Enum.map(crash.steps, &{&1.name, &1.role}) == [
             {"knn_bootstrap.root", :teacher},
             {"root", :target}
           ]

    assert {:ok, _payment} = Tune.Runtime.run(knn(), %{ticket: "card payment refund"}, opts)

    [crash_target, payment_target] = Transport.requests(target)
    assert Transport.prompt_text(crash_target) =~ "the app crashes on start"
    refute Transport.prompt_text(crash_target) =~ "refund my card payment"
    assert Transport.prompt_text(payment_target) =~ "refund my card payment"
    assert length(Transport.requests(teacher)) == 2
  end

  test "ties keep pool order and k bounds the neighbors" do
    teacher = echo_teacher()
    target = Transport.respond_with(fn _ -> Transport.chat(label: "billing") end)

    assert {:ok, result} =
             Tune.Runtime.run(knn(k: 2), %{ticket: "zzz"},
               model: config(target),
               teacher: config(teacher),
               max_model_calls: 10
             )

    assert result.calls == %{teacher: 2, target: 1}
    [first, second] = Transport.requests(teacher)
    assert Transport.last_user_text(first) =~ "refund my card payment"
    assert Transport.last_user_text(second) =~ "the app crashes on start"
  end

  test "running requires a teacher and an explicit call limit" do
    stub = Transport.respond_with(fn _ -> Transport.chat(label: "billing") end)

    assert {:error, %Error.Execution.Failed{cause: %Error.Invalid.Option{option: :teacher}}} =
             Tune.Runtime.run(knn(), %{ticket: "x"}, model: config(stub), max_model_calls: 5)

    assert {:error,
            %Error.Execution.Failed{cause: %Error.Invalid.Option{option: :max_model_calls}}} =
             Tune.Runtime.run(knn(), %{ticket: "x"}, model: config(stub), teacher: config(stub))

    assert Transport.requests(stub) == []
  end

  test "the call limit covers runtime bootstrap calls" do
    teacher = echo_teacher()
    target = Transport.respond_with(fn _ -> Transport.chat(label: "billing") end)

    assert {:error,
            %Error.Execution.Failed{
              cause: %Error.Execution.LimitReached{limit: :model_calls},
              result: result
            }} =
             Tune.Runtime.run(knn(k: 3), %{ticket: "x"},
               model: config(target),
               teacher: config(teacher),
               max_model_calls: 3
             )

    assert result.calls == %{teacher: 3}
    assert Transport.requests(target) == []
  end

  test "runs leave the program unchanged" do
    program = knn()
    teacher = echo_teacher()
    target = Transport.respond_with(fn _ -> Transport.chat(label: "billing") end)

    {:ok, _} =
      Tune.Runtime.run(program, %{ticket: "crash"},
        model: config(target),
        teacher: config(teacher),
        max_model_calls: 5
      )

    assert program.inner.demos == []
  end

  test "an incompatible pool is rejected and an empty pool runs without demos" do
    assert {:error, %Error.Invalid.Definition{}} =
             KNN.new(classifier(), pool: [%{inputs: %{text: "x"}}])

    {:ok, empty} = KNN.new(classifier(), pool: [])
    target = Transport.respond_with(fn _ -> Transport.chat(label: "billing") end)

    assert {:ok, result} =
             Tune.Runtime.run(empty, %{ticket: "x"},
               model: config(target),
               teacher: config(target),
               max_model_calls: 2
             )

    assert result.calls == %{target: 1}
  end

  test "the pool round-trips through an artifact into matching code" do
    {:ok, artifact} = Parameters.dump(knn())
    {:ok, json} = Parameters.encode(artifact)
    {:ok, decoded} = Parameters.decode(json)
    {:ok, fresh} = KNN.new(classifier(), pool: [], k: 1)

    assert {:ok, loaded} = Parameters.apply(fresh, decoded)
    assert loaded.pool.value == knn().pool.value
  end

  test "a custom vectorizer drives selection" do
    vectorizer = fn inputs -> [if(inputs["ticket"] =~ "invoice", do: 1, else: 0), 1] end
    teacher = echo_teacher()
    target = Transport.respond_with(fn _ -> Transport.chat(label: "billing") end)

    {:ok, _} =
      Tune.Runtime.run(knn(vectorizer: vectorizer), %{ticket: "invoice question"},
        model: config(target),
        teacher: config(teacher),
        max_model_calls: 5
      )

    [request] = Transport.requests(teacher)
    assert Transport.last_user_text(request) =~ "invoice payment failed twice"
  end
end
