defmodule Tune.Contracts.FailurePathsTest do
  use ExUnit.Case, async: true

  alias Tune.Error
  alias Tune.Examples.Support.Transport
  alias Tune.ModelConfig
  alias Tune.Predictor
  alias Tune.Program
  alias Tune.Result

  defmodule ProgramContract do
    @behaviour Tune.Program
    defstruct [:signature, :parameters, :invoke, write: :apply]

    def signature(program), do: program.signature
    def parameters(program), do: program.parameters
    def put_parameters(%{write: :ignore} = program, _values), do: program
    def put_parameters(%{write: :wrong_type}, _values), do: :invalid
    def put_parameters(%{write: :corrupt} = program, _values), do: %{program | parameters: []}
    def put_parameters(program, values), do: %{program | parameters: values}
    def call(%{invoke: nil}, _inputs, execution), do: {:ok, %{}, execution}
    def call(%{invoke: invoke}, inputs, execution), do: invoke.(inputs, execution)
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
            %Error.Invalid.Dataset{
              split: :test,
              cause: %ArgumentError{message: "data must implement Enumerable"}
            }} =
             study |> Tune.data(test: fn -> :invalid end) |> Tune.compare(winner, split: :test)

    assert {:error, %Error.Invalid.Option{option: :data, message: "comparison data is empty"}} =
             study |> Tune.data(test: []) |> Tune.compare(winner, split: :test)

    assert {:ok, %{case_ids: [], complete?: true}} =
             study
             |> Tune.data(test: [1])
             |> Tune.limit(cases: 0)
             |> Tune.compare(winner, split: :test)
  end

  test "a program failure after dispatch preserves the shared call budget", %{
    predictor: predictor
  } do
    rows = for question <- ["first", "second"], do: %{input: %{question: question}}

    for fail <- [fn -> raise "callback failed" end, fn -> :invalid_reply end] do
      stub = Transport.script([Transport.chat(answer: "ok")])

      target = %ProgramContract{
        signature: predictor.signature,
        parameters: %{"root" => predictor},
        invoke: fn input, execution ->
          {:ok, _answer, _updated} = Tune.Execution.predict(execution, "root", input)
          fail.()
        end
      }

      study =
        target
        |> Tune.new(model: model_options(stub))
        |> Tune.data(test: rows)
        |> Tune.score(:score, fn _ -> flunk("invalid output was scored") end)
        |> Tune.limit(model_calls: 1)

      assert {:ok, report} = Tune.compare(study, %Result{value: target}, split: :test)
      refute report.complete?
      assert report.baseline.calls == %{target: 1}
      assert report.challenger.calls == %{}
      assert report.challenger.stop_reason == :model_call_limit

      assert [%{error: %Error.Execution.Failed{} = error}, %{status: :skipped}] =
               report.baseline.observations

      assert error.result.calls == %{target: 1}
      assert [%Tune.Step{name: "root"}] = error.result.steps
      assert report.baseline.usage.total == 15

      assert report.baseline.metadata.successful_models == [
               %{role: :target, model: "openai:gpt-4-turbo"}
             ]

      assert length(Transport.requests(stub)) == 1
    end
  end

  test "an execution cannot dispatch from background work after comparison", %{
    predictor: predictor
  } do
    owner = self()
    stub = Transport.respond_with(fn _ -> Transport.chat(answer: "late") end)

    target = %ProgramContract{
      signature: predictor.signature,
      parameters: %{"root" => predictor},
      invoke: fn input, execution ->
        {:ok, worker} =
          Task.start(fn ->
            receive do
              :proceed ->
                result = Tune.Execution.predict(execution, "root", input)
                send(owner, {:late_result, self(), result})
            after
              2_000 -> :ok
            end
          end)

        send(owner, {:late_worker, worker})
        {:ok, %{"answer" => "queued"}, execution}
      end
    }

    study =
      target
      |> Tune.new(model: model_options(stub))
      |> Tune.data(test: [%{input: %{question: "question"}}])
      |> Tune.score(:score, fn _ -> 1 end)
      |> Tune.limit(model_calls: 1)

    assert {:ok, %{complete?: true} = report} =
             Tune.compare(study, %Result{value: target}, split: :test)

    assert report.baseline.calls == %{}
    assert report.challenger.calls == %{}

    for _ <- 1..2 do
      assert_received {:late_worker, worker}
      send(worker, :proceed)
      assert_receive {:late_result, ^worker, {:error, %Error.Execution.Callback{}, _}}, 1_000
    end

    assert Transport.requests(stub) == []
  end

  test "a row call cap leaves room for the next row and the challenger", %{predictor: predictor} do
    stub = Transport.respond_with(fn _ -> Transport.chat(answer: "ok") end)
    target = counted_program(predictor)

    study =
      target
      |> Tune.new(model: model_options(stub))
      |> Tune.data(test: call_rows([2, 1]))
      |> Tune.score(:score, fn _ -> 1 end)
      |> Tune.limit(model_calls: 10, row_calls: 1, concurrency: 2)

    assert {:ok, report} = Tune.compare(study, %Result{value: target}, split: :test)
    assert report.complete?

    for pass <- [report.baseline, report.challenger] do
      assert pass.stop_reason == :completed
      assert pass.calls == %{target: 2}
      assert [%{id: "2", status: :error}, %{id: "1", status: :ok}] = pass.observations
    end

    assert report.metrics.score.counts == %{error: 1, tied: 1}
    assert length(Transport.requests(stub)) == 4
  end

  test "comparison validates an invalid challenger before any calls", %{predictor: predictor} do
    stub = Transport.script([Transport.chat(answer: "ok")])

    study =
      predictor
      |> Tune.new(model: model_options(stub))
      |> Tune.data(test: [%{input: %{question: "question"}}])
      |> Tune.score(:score, fn _ -> 1 end)

    assert {:error, %Error.Execution.Callback{}} =
             Tune.compare(study, %Result{value: :not_a_program}, split: :test)

    assert {:ok, incompatible} =
             Predictor.new(
               signature: [inputs: [other: Zoi.string()], outputs: [answer: Zoi.string()]]
             )

    assert {:error, %Error.Invalid.Option{option: :compare}} =
             Tune.compare(study, %Result{value: incompatible}, split: :test)

    assert Transport.requests(stub) == []
  end

  test "zero cases skips opening the dataset" do
    factory = fn -> flunk("opened a zero-case dataset") end

    study =
      Tune.new(1, run: fn _ -> flunk("ran a zero-case target") end)
      |> Tune.data(test: factory)
      |> Tune.score(:score, & &1)
      |> Tune.limit(cases: 0)

    assert {:ok, %{case_ids: [], complete?: true}} =
             Tune.compare(study, %Result{value: 2}, split: :test)

    assert {:ok, %{observations: [], stop_reason: :case_limit, complete?: true}} =
             Tune.evaluate(study)
  end

  test "synchronous comparison preserves case order and stays within every budget", %{
    predictor: predictor
  } do
    target = counted_program(predictor)
    rows = call_rows([1, 2, 3])

    for budget <- 0..12, cap <- [nil, 1, 2, 3], concurrency <- [1, 2, 4] do
      stub = Transport.respond_with(fn _ -> Transport.chat(answer: "ok") end)
      limits = [model_calls: budget, concurrency: concurrency]
      limits = if cap, do: Keyword.put(limits, :row_calls, cap), else: limits

      study =
        target
        |> Tune.new(model: model_options(stub))
        |> Tune.data(test: rows)
        |> Tune.score(:score, fn _ -> 1 end)
        |> Tune.limit(limits)

      assert {:ok, report} = Tune.compare(study, %Result{value: target}, split: :test)
      requests = length(Transport.requests(stub))
      trial = inspect(limits)

      assert requests <= budget, trial

      assert Map.get(report.baseline.calls, :target, 0) +
               Map.get(report.challenger.calls, :target, 0) == requests,
             trial

      assert report.baseline.usage.total + report.challenger.usage.total == 15 * requests, trial
      assert report.case_ids == if(budget == 0, do: [], else: ["1", "2", "3"]), trial

      for pass <- [report.baseline, report.challenger] do
        ids = Enum.map(pass.observations, & &1.id)
        assert ids == Enum.take(report.case_ids, length(ids)), trial
      end
    end
  end

  defp call_rows(counts) do
    for count <- counts, id = Integer.to_string(count), do: %{id: id, input: %{question: id}}
  end

  defp counted_program(predictor) do
    %ProgramContract{
      signature: predictor.signature,
      parameters: %{"root" => predictor},
      invoke: fn input, execution ->
        count = String.to_integer(input["question"])

        Enum.reduce_while(1..count, {:ok, %{}, execution}, fn _, {:ok, _, execution} ->
          case Tune.Execution.predict(execution, "root", input) do
            {:ok, _, _} = result -> {:cont, result}
            error -> {:halt, error}
          end
        end)
      end
    }
  end

  test "reusing earlier execution state does not reset the allowance", %{predictor: predictor} do
    stub = Transport.script([Transport.chat(answer: "ok")])

    target = %ProgramContract{
      signature: predictor.signature,
      parameters: %{"root" => predictor},
      invoke: fn input, execution ->
        {:ok, _answer, _updated} = Tune.Execution.predict(execution, "root", input)
        Tune.Execution.predict(execution, "root", input)
      end
    }

    assert {:error,
            %Error.Execution.Failed{
              cause: %Error.Execution.LimitReached{limit: :model_calls},
              result: %{calls: %{target: 1}}
            }} =
             Tune.Runtime.run(target, %{question: "A?"},
               model: model_options(stub),
               max_model_calls: 1
             )

    assert length(Transport.requests(stub)) == 1
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

  test "invalid evaluation splits identify the allowed values without opening data" do
    study =
      Tune.replay(fn -> flunk("dataset opened for an invalid split") end)
      |> Tune.score(:value, & &1)

    assert {:error, %Error.Invalid.Option{option: :split, message: message}} =
             Tune.evaluate(study, "test")

    assert message =~ "expected :train, :validation, or :test"
  end

  test "comparison rejects replay studies before reading the saved rows" do
    study =
      Tune.replay(fn -> flunk("dataset opened for an unsupported comparison") end)
      |> Tune.score(:value, & &1)

    assert {:error, %Error.Invalid.Option{option: :compare, message: message}} =
             Tune.compare(study, %Result{value: :winner}, split: :test)

    assert message =~ "Use Tune.evaluate/1"
  end

  test "returns the split and the original stream error for each evaluation path", %{
    predictor: predictor
  } do
    source = Stream.map([:bad_row], fn _ -> raise "malformed JSONL row" end)
    stub = Transport.script([])

    studies = [
      {Tune.replay(source), :test},
      {Tune.new(:target, run: fn _ -> flunk("runner started") end)
       |> Tune.data(train: source), :train},
      {Tune.new(predictor, model: model_options(stub)) |> Tune.data(validation: source),
       :validation}
    ]

    for {study, split} <- studies do
      assert {:error,
              %Error.Invalid.Dataset{
                split: ^split,
                cause: %RuntimeError{message: "malformed JSONL row"}
              } = error} = study |> Tune.score(:value, & &1) |> Tune.evaluate(split)

      assert Exception.message(error) =~ inspect(split)
    end

    assert Transport.requests(stub) == []
  end

  test "a progress exception closes the paused stream and preserves the original error" do
    owner = self()

    rows =
      Stream.resource(
        fn -> 0 end,
        fn n -> {[%{input: n, output: n}], n + 1} end,
        fn _ -> send(owner, :stream_closed) end
      )

    study =
      Tune.replay(rows, on_progress: fn _ -> raise "progress callback failed" end)
      |> Tune.score(:value, & &1)

    assert_raise RuntimeError, "progress callback failed", fn -> Tune.evaluate(study) end
    assert_received :stream_closed
  end

  test "factory and stream errors have the same contract for evaluation, comparison, and search" do
    fail = fn -> raise "dataset failed" end

    for source <- [fail, Stream.map([1], fn _ -> fail.() end)] do
      study =
        Tune.new(%{value: 1}, run: fn _ -> flunk("runner started") end)
        |> Tune.data(test: source, validation: source)
        |> Tune.score(:score, & &1)
        |> Tune.vary(value: 1..2)

      for {split, result} <- [
            test: Tune.evaluate(study),
            test: Tune.compare(study, %Result{value: %{value: 2}}, split: :test),
            validation: study |> Tune.search(:grid) |> Tune.tune(),
            validation:
              study |> Tune.search(:genetic) |> Tune.limit(evaluations: 2) |> Tune.tune()
          ] do
        assert {:error,
                %Error.Invalid.Dataset{
                  split: ^split,
                  cause: %RuntimeError{message: "dataset failed"}
                }} = result
      end
    end
  end

  test "comparison and grid search stop blocked snapshot reads before target work" do
    owner = self()

    blocked = fn ->
      send(owner, {:reader, self()})
      Process.sleep(3_000)
      [1]
    end

    study =
      Tune.new(%{value: 1}, run: fn _ -> send(owner, :runner_started) end)
      |> Tune.score(:score, & &1)
      |> Tune.limit(deadline: 250)

    assert {:ok,
            %{
              complete?: false,
              baseline: %{stop_reason: :deadline},
              challenger: %{stop_reason: :deadline}
            }} =
             study
             |> Tune.data(test: blocked)
             |> Tune.compare(%Result{value: %{value: 2}}, split: :test)

    assert_received {:reader, reader}
    refute Process.alive?(reader)

    assert {:error, %Error.Optimization.Failed{report: %{stop_reason: :deadline, history: []}}} =
             study
             |> Tune.data(validation: Stream.flat_map([1], fn _ -> blocked.() end))
             |> Tune.vary(value: 1..2)
             |> Tune.search(:grid)
             |> Tune.tune()

    assert_received {:reader, reader}
    refute Process.alive?(reader)
    refute_received :runner_started
  end

  test "replay keeps finished rows when cancellation stops a blocked stream" do
    owner = self()
    cancel = :atomics.new(1, [])

    rows =
      Stream.map([1, 2], fn
        1 ->
          %{id: "first", input: 1, output: 2}

        2 ->
          send(owner, {:reader, self()})
          :atomics.put(cancel, 1, 1)
          Process.sleep(3_000)
          %{id: "second", input: 2, output: 3}
      end)

    assert {:ok, report} =
             rows
             |> Tune.replay(cancel: fn -> :atomics.get(cancel, 1) == 1 end)
             |> Tune.score(:value, & &1)
             |> Tune.evaluate()

    refute report.complete?
    assert report.stop_reason == :cancelled
    assert report.calls == %{}
    assert [%{id: "first", scores: %{value: 2}}] = report.observations
    assert_received {:reader, reader}
    refute Process.alive?(reader)
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

    assert {:error,
            %Error.Invalid.Dataset{
              split: :train,
              cause: %RuntimeError{message: "training rows unavailable"}
            }} =
             study
             |> Tune.data(
               train: Stream.map([:unavailable], fn _ -> raise "training rows unavailable" end)
             )
             |> Tune.tune()

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
