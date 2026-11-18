defmodule Tune.Contracts.FailurePathsTest do
  use ExUnit.Case, async: true

  alias Tune.Error
  alias Tune.ModelConfig
  alias Tune.Predictor
  alias Tune.Program
  alias Tune.Result
  alias Tune.TestSupport.Transport

  defmodule ProgramContract do
    @behaviour Tune.Program
    defstruct [:signature, :parameters, write: :apply]

    def signature(program), do: program.signature
    def parameters(program), do: program.parameters
    def put_parameters(%{write: :ignore} = program, _values), do: program
    def put_parameters(%{write: :wrong_type}, _values), do: :invalid
    def put_parameters(%{write: :corrupt} = program, _values), do: %{program | parameters: []}
    def put_parameters(program, values), do: %{program | parameters: values}
    def call(_program, _inputs, execution), do: {:ok, %{}, execution}
  end

  defmodule MatchScore do
    def score(row, actual), do: {:ok, if(actual == row.expected, do: 1, else: 0)}
  end

  setup do
    assert {:ok, predictor} =
             Predictor.new(
               signature: [
                 inputs: [question: Zoi.string()],
                 outputs: [answer: Zoi.string()]
               ]
             )

    %{predictor: predictor}
  end

  test "comparison reports empty splits and failures while reading them without running targets" do
    study =
      Tune.new(:target, run: fn _, _ -> flunk("target started") end) |> Tune.score(:score, & &1)

    winner = %Result{value: :winner}

    assert {:error,
            %Error.Invalid.Option{option: :test, message: "data must implement Enumerable"}} =
             study |> Tune.data(test: fn -> :invalid end) |> Tune.compare(winner, split: :test)

    assert {:error, %Error.Invalid.Option{option: :test, message: message}} =
             study
             |> Tune.data(test: fn -> raise "factory failed" end)
             |> Tune.compare(winner, split: :test)

    assert message =~ "factory failed"

    assert {:error, %Error.Invalid.Option{option: :data, message: message}} =
             study
             |> Tune.data(test: Stream.map([1], fn _ -> raise "row unavailable" end))
             |> Tune.compare(winner, split: :test)

    assert message =~ "row unavailable"

    assert {:error, %Error.Invalid.Option{option: :data, message: "comparison data is empty"}} =
             study |> Tune.data(test: []) |> Tune.compare(winner, split: :test)

    assert {:ok, %{case_ids: [], complete?: true}} =
             study
             |> Tune.data(test: [1])
             |> Tune.limit(cases: 0)
             |> Tune.compare(winner, split: :test)
  end

  test "cancels evaluation before opening a factory and honors zero cases on a typed study", %{
    predictor: predictor
  } do
    study =
      Tune.new(:target, run: fn _, _ -> flunk("target started") end, cancel: fn -> true end)
      |> Tune.data(test: fn -> flunk("dataset opened") end)
      |> Tune.score(:score, & &1)

    assert {:ok, %{complete?: false, stop_reason: :cancelled, observations: []}} =
             Tune.evaluate(study)

    stub = Transport.script([])

    assert {:ok, %{stop_reason: :case_limit, observations: []}} =
             Tune.new(predictor, model: model_options(stub))
             |> Tune.data(test: Stream.map([1], fn _ -> flunk("dataset read") end))
             |> Tune.score(:score, fn _ -> flunk("score ran") end)
             |> Tune.limit(cases: 0)
             |> Tune.evaluate()

    assert Transport.requests(stub) == []
  end

  test "rejects invalid search strategies and spaces before opening the dataset", %{
    predictor: predictor
  } do
    generic =
      Tune.new(%{value: 0}, run: fn _, input -> input end)
      |> Tune.data(validation: fn -> flunk("dataset opened") end)
      |> Tune.score(:score, & &1)
      |> Tune.limit(evaluations: 2)

    assert {:error, %Error.Invalid.Option{option: :search}} = Tune.tune(generic)

    assert {:error, %Error.Invalid.Option{option: :search}} =
             generic |> Tune.search(:copro) |> Tune.tune()

    assert {:error, %Error.Invalid.Option{option: :vary}} =
             generic |> Tune.search(:genetic) |> Tune.tune()

    assert {:error, %Error.Invalid.Definition{}} =
             generic |> Tune.vary(value: {:float, 5, 3}) |> Tune.search(:genetic) |> Tune.tune()

    program = Tune.new(predictor)
    assert {:error, %Error.Invalid.Option{option: :search}} = Tune.tune(program)

    assert {:error, %Error.Invalid.Option{option: :search}} =
             program |> Tune.search(:unregistered) |> Tune.tune()

    assert {:error, %Error.Invalid.Option{option: :search, message: message}} =
             [%{input: :question, output: :answer}] |> Tune.replay() |> Tune.tune()

    assert message =~ "evaluation only"
  end

  test "composed preview requires a predictor name and a model", %{predictor: predictor} do
    stub = Transport.script([])
    {:ok, parameter} = Tune.Parameter.new(schema: Zoi.string(), value: "data")

    program = %ProgramContract{
      signature: predictor.signature,
      parameters: %{"prompt" => predictor, "value" => parameter}
    }

    input = %{question: "question"}

    assert {:error, %Error.Invalid.Option{option: :model}} =
             Tune.preview(Tune.new(program), input)

    study = Tune.new(program, model: model_options(stub))

    for {requested, expected} <- [
          {input, "requires {predictor_name, inputs}"},
          {{"missing", input}, "unknown predictor"},
          {{"value", input}, "is not a predictor"}
        ] do
      assert {:error, %Error.Invalid.Option{option: :preview, message: message}} =
               Tune.preview(study, requested)

      assert message =~ expected
    end

    assert {:ok, prepared} = Tune.preview(study, {"prompt", input})
    assert prepared.inputs == %{"question" => "question"}
    assert Transport.requests(stub) == []
  end

  test "program callback contract errors identify invalid declarations and failed writes", %{
    predictor: predictor
  } do
    program = %ProgramContract{
      signature: predictor.signature,
      parameters: %{"root" => predictor}
    }

    assert {:error, %Error.Execution.Callback{message: message}} =
             Program.signature(%{program | signature: :bad})

    assert message =~ "return a Signature"
    assert {:error, %Error.Execution.Callback{}} = Program.signature(:not_a_program)
    assert {:error, %Error.Execution.Callback{}} = Program.signature(~D[2026-01-01])
    assert {:error, %Error.Execution.Callback{}} = Program.parameters(:not_a_program)

    for {parameters, expected} <- [
          {[], "must return a map"},
          {%{root: predictor}, "invalid entry"}
        ] do
      assert {:error, %Error.Execution.Callback{message: message}} =
               Program.parameters(%{program | parameters: parameters})

      assert message =~ expected
    end

    assert {:ok, revised} = Predictor.put_instructions(predictor, "Use the revised wording.")

    for {mode, expected} <- [
          {:ignore, "did not apply every value"},
          {:corrupt, "must return a map"},
          {:wrong_type, "must return a"}
        ] do
      assert {:error, %Error.Execution.Callback{message: message}} =
               Program.replace_parameters(%{program | write: mode}, %{"root" => revised})

      assert message =~ expected
    end

    assert program.parameters == %{"root" => predictor}
  end

  test "direct predictor calls validate inputs and keep truncated response evidence", %{
    predictor: predictor
  } do
    stub = Transport.script([{:text, "incomplete", "length"}, Transport.chat(answer: "Paris")])
    assert {:ok, config} = ModelConfig.new(model_options(stub))

    assert {:error, %Error.Invalid.Input{}} = Predictor.call(predictor, %{}, config)
    assert Transport.requests(stub) == []

    assert {:error, %Error.Output.Rejected{reason: :finish_reason, response: response}} =
             Predictor.call(predictor, %{question: "where?"}, config)

    assert response.finish_reason == :length

    assert {:ok, %Tune.Step{outputs: %{"answer" => "Paris"}}} =
             Predictor.call(predictor, %{question: "where?"}, config, 1_000)

    assert length(Transport.requests(stub)) == 2
  end

  test "replay keeps callback failure and missing-row evidence with a successful metric" do
    study =
      [%{id: "saved", input: "where?", expected: "Paris", output: "Paris"}, :invalid_row]
      |> Tune.replay()
      |> Tune.score(:exact, MatchScore, argument: :output)
      |> Tune.score(:broken, fn _ -> throw(:unavailable) end)
      |> Tune.score(:undefined, __MODULE__)

    assert {:ok, report} = Tune.evaluate(study)
    assert report.calls == %{}

    assert [
             %{
               id: "saved",
               scores: %{exact: 1},
               score_errors: %{
                 broken: %Error.Execution.Callback{value: :unavailable},
                 undefined: _
               }
             },
             %{id: "1", status: :error, error: %Error.Invalid.Definition{}}
           ] = report.observations
  end

  test "a selector rejects undeclared scores and ranges before opening data" do
    study =
      Tune.new(:target, run: fn _, _ -> flunk("runner started") end)
      |> Tune.data(test: fn -> flunk("data opened") end)
      |> Tune.score(:accuracy, & &1)

    assert {:error, %Error.Invalid.Option{option: :selector, message: message}} =
             study |> Tune.select(:missing) |> Tune.evaluate()

    assert message =~ "unknown score"

    assert {:error, %Error.Invalid.Option{option: :selector, message: message}} =
             study |> Tune.select(weighted: [accuracy: 1]) |> Tune.evaluate()

    assert message =~ "explicit ranges"

    assert_raise ArgumentError, ~r/score must be a function/, fn ->
      Tune.score(study, :bad, "not a callback")
    end

    assert_raise ArgumentError, ~r/applies to two-argument scorers/, fn ->
      Tune.score(study, :bad, & &1, argument: :prediction)
    end
  end

  test "program searches stop before data access and report a fault while loading training data",
       %{
         predictor: predictor
       } do
    stub = Transport.script([])
    study = predictor |> Tune.new(model: model_options(stub)) |> Tune.search(:labeled_few_shot)

    assert {:error,
            %Error.Optimization.Failed{report: %{complete?: false, stop_reason: :deadline}}} =
             study
             |> Tune.data(train: fn -> flunk("factory opened after deadline") end)
             |> Tune.limit(deadline: 0)
             |> Tune.tune()

    assert {:error, %Error.Invalid.Option{option: :data, message: message}} =
             study
             |> Tune.data(
               train: Stream.map([:unavailable], fn _ -> raise "training rows unavailable" end)
             )
             |> Tune.tune()

    assert message =~ "training rows unavailable"
    assert Transport.requests(stub) == []
  end

  test "genetic search rejects invalid seed populations before accessing data" do
    study =
      Tune.new(%{value: 0, fixed: :original}, run: fn _, input -> input end)
      |> Tune.data(validation: fn -> flunk("factory opened for invalid population") end)
      |> Tune.score(:score, & &1)
      |> Tune.vary(value: 0..2)
      |> Tune.limit(evaluations: 2)

    seeds = for value <- 0..2, do: %{value: value, fixed: :original}

    for {opts, expected} <- [
          {[population_size: 2, initial_population: [hd(seeds)]], "exactly population_size"},
          {[population_size: 2, elitism: 3], "elitism"},
          {[initial_population: [%{value: 1, fixed: :changed}]], "outside declared variations"},
          {[initial_population: [%{value: 3, fixed: :original}]], "outside the declared spaces"},
          {[mutate: fn _, state -> {nil, state} end], "without named variations"},
          {[initial_population: seeds], "cover the initial population"}
        ] do
      assert {:error, %Error.Invalid.Option{option: :genetic, message: message}} =
               study |> Tune.search(:genetic, opts) |> Tune.tune()

      assert message =~ expected
    end
  end

  test "a generic artifact rejects mismatched fields and value types" do
    parameters = %{setting: %{"enabled" => true, "levels" => [1.0, nil]}}
    result = %Result{value: parameters, parameters: parameters, metadata: %{strategy: :grid}}
    assert {:ok, artifact} = Tune.dump(result)
    assert {:ok, json} = Tune.Artifact.encode(artifact)
    assert {:ok, decoded} = Tune.Artifact.decode(json)

    assert {:ok, ^parameters} =
             Tune.load(decoded, %{setting: %{enabled: false, levels: [2.0, nil]}})

    for target <- [:invalid_target, %{other: 1}, %{setting: %{enabled: false, levels: [2, nil]}}] do
      assert {:error, %Error.Invalid.Definition{}} = Tune.load(decoded, target)
    end
  end

  defp model_options(stub) do
    [
      model: Transport.model(),
      adapter: Tune.Adapter.Chat,
      request_options: Transport.request_options(stub)
    ]
  end
end
