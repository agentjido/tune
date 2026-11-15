defmodule Tune.PipelineTest do
  use ExUnit.Case, async: true

  alias Tune.Adapter.Chat
  alias Tune.Artifact
  alias Tune.Predictor
  alias Tune.Result
  alias Tune.TestSupport.Transport

  defp predictor do
    {:ok, predictor} =
      Predictor.new(signature: [inputs: [text: Zoi.string()], outputs: [label: Zoi.string()]])

    predictor
  end

  defp model(stub) do
    [
      model: Transport.model(),
      adapter: Chat,
      request_options: Transport.request_options(stub)
    ]
  end

  defmodule RepeatValidation do
    @behaviour Tune.Search.ProgramStrategy

    alias Tune.Search.Program.Context

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def requirements(_opts),
      do: %{datasets: [:val], roles: [], model_calls?: true, metric?: true}

    @impl true
    def compile(_opts, program, ctx) do
      {_first, ctx} = Context.evaluate_validation(ctx, program)
      {second, ctx} = Context.evaluate_validation(ctx, program)
      {_id, ctx} = Context.consider(ctx, program, second)
      Context.best(ctx)
    end
  end

  test "program search requests fresh validation data for each candidate" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    validation = fn ->
      Agent.update(counter, &(&1 + 1))
      [%{input: %{text: "a"}, expected: %{label: "A"}}]
    end

    stub = Transport.respond_with(fn _body -> Transport.chat(label: "A") end)

    assert {:ok, %Result{}} =
             predictor()
             |> Tune.new(model: model(stub))
             |> Tune.data(validation: validation)
             |> Tune.score(:correct, fn tune_case, prediction ->
               if prediction.output == tune_case.expected, do: 1.0, else: 0.0
             end)
             |> Tune.search(RepeatValidation)
             |> Tune.limit(model_calls: 2)
             |> Tune.tune()

    assert Agent.get(counter, & &1) == 3
  end

  test "the facade contains only the selected workflow names" do
    functions = Tune.__info__(:functions) |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    assert MapSet.subset?(
             MapSet.new([
               :new,
               :data,
               :vary,
               :score,
               :select,
               :search,
               :limit,
               :preview,
               :evaluate,
               :tune,
               :dump,
               :load
             ]),
             functions
           )

    refute MapSet.member?(functions, :run)
    refute MapSet.member?(functions, :optimize)
    refute MapSet.member?(functions, :parameters)
    refute MapSet.member?(functions, :replace_parameters)
  end

  test "builders return new pipeline values and perform no request" do
    stub = Transport.script([])

    original = Tune.new(predictor(), model: model(stub))

    configured =
      original
      |> Tune.data(train: [%{input: %{text: "a"}, expected: %{label: "A"}}])
      |> Tune.score(:correct, fn _example, _prediction -> 1.0 end)
      |> Tune.search(:labeled_few_shot, k: 1)
      |> Tune.limit(model_calls: 10)

    assert %Tune{} = configured
    assert original.data == %{}
    assert configured.data.train != []
    assert Transport.requests(stub) == []
  end

  test "preview renders a request without executing it" do
    stub = Transport.script([])

    assert {:ok, prepared} =
             predictor()
             |> Tune.new(model: model(stub))
             |> Tune.preview(%{text: "hello"})

    assert prepared.inputs == %{"text" => "hello"}
    assert Transport.requests(stub) == []
  end

  test "a training-only optimizer returns Tune.Result and reloads its artifact" do
    source = predictor()
    rows = [%{input: %{text: "a"}, expected: %{label: "A"}}]

    assert {:ok, %Result{} = result} =
             source
             |> Tune.new(model: model(:unused))
             |> Tune.data(train: rows)
             |> Tune.search(:labeled_few_shot, k: 1, sample: false)
             |> Tune.tune()

    assert result.complete?
    assert result.stop_reason == :completed
    assert [%{outputs: %{"label" => "A"}}] = result.value.demos

    assert {:ok, artifact} = Tune.dump(result)
    assert {:ok, json} = Artifact.encode(artifact)
    assert {:ok, decoded} = Artifact.decode(json)
    assert {:ok, loaded} = Tune.load(decoded, predictor())
    assert loaded.demos == result.value.demos
  end

  test "artifact decoding rejects fields outside the public contract" do
    json =
      JSON.encode!(%{
        "version" => 1,
        "target_fingerprint" => "fingerprint",
        "parameters" => %{},
        "provenance" => %{},
        "runtime_options" => %{}
      })

    assert {:error, %Tune.Error.Invalid.Definition{}} = Artifact.decode(json)
  end

  test "multiple scores require an explicit selector" do
    pipeline =
      predictor()
      |> Tune.new(model: model(:unused))
      |> Tune.data(test: [%{input: %{text: "a"}, expected: %{label: "A"}}])
      |> Tune.score(:first, fn _example, _prediction -> 1.0 end)
      |> Tune.score(:second, fn _example, _prediction -> 1.0 end)

    assert {:error, %Tune.Error.Invalid.Option{option: :selector}} = Tune.evaluate(pipeline)
  end

  test "weighted selection requires explicit ranges" do
    pipeline =
      Tune.new(%{}, run: fn _target, input -> input end)
      |> Tune.data(test: [1])
      |> Tune.score(:first, & &1)
      |> Tune.score(:second, & &1)
      |> Tune.select(weighted: [first: 0.5, second: 0.5])

    assert {:error, %Tune.Error.Invalid.Option{option: :selector}} = Tune.evaluate(pipeline)
  end

  test "evaluation retains named raw scores and separate weighted selection" do
    assert {:ok, evaluation} =
             Tune.new(%{}, run: fn _target, input -> input end)
             |> Tune.data(test: [0, 2])
             |> Tune.score(:value, & &1, range: {0, 2})
             |> Tune.score(:inverse, &(2 - &1), range: {0, 2})
             |> Tune.select(weighted: [value: 0.5, inverse: 0.5])
             |> Tune.evaluate()

    assert Enum.map(evaluation.observations, & &1.scores) == [
             %{value: 0, inverse: 2},
             %{value: 2, inverse: 0}
           ]

    assert evaluation.summaries.value.mean == 1.0
    assert evaluation.summaries.inverse.mean == 1.0
    assert evaluation.selected_score == 0.5
    assert evaluation.eligible?
  end

  test "an explicit failure score keeps failed rows eligible" do
    assert {:ok, evaluation} =
             Tune.new(%{},
               run: fn
                 _target, :fail -> raise "failed row"
                 _target, value -> value
               end
             )
             |> Tune.data(test: [1.0, :fail])
             |> Tune.score(:value, & &1, failure_score: 0.0)
             |> Tune.evaluate()

    assert Enum.map(evaluation.observations, & &1.status) == [:ok, :error]
    assert evaluation.eligible?
    assert evaluation.selected_score == 0.5
  end
end
