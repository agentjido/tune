defmodule Tune.CompositionTest do
  use ExUnit.Case, async: true

  alias Tune
  alias Tune.Adapter
  alias Tune.Error
  alias Tune.Examples.GroundedQA
  alias Tune.Execution
  alias Tune.Parameter
  alias Tune.Predictor
  alias Tune.Result
  alias Tune.TestSupport.Transport

  @inputs %{
    context: [
      %{"id" => "p1", "text" => "The Eiffel Tower is in Paris."},
      %{"id" => "p2", "text" => "Paris is the capital of France."}
    ],
    question: "Where is the Eiffel Tower?"
  }

  @facts [%{"text" => "The Eiffel Tower is in Paris.", "source" => "p1"}]

  defp model(stub),
    do: [
      model: Transport.model(),
      adapter: Adapter.Chat,
      request_options: Transport.request_options(stub)
    ]

  defp facts_reply, do: Transport.chat(facts: @facts)
  defp answer_reply, do: Transport.chat(answer: "Paris", sources: ["p1"])

  describe "grounded QA" do
    test "runs extraction then answering and records both steps in order" do
      stub = Transport.script([facts_reply(), answer_reply()])

      assert {:ok, %Result{} = result} =
               Tune.run(GroundedQA.new(), @inputs, model: model(stub))

      assert result.output == %{"answer" => "Paris", "sources" => ["p1"]}
      assert Enum.map(result.steps, & &1.name) == ["extract", "answer"]
      assert Enum.map(result.steps, & &1.role) == [:target, :target]
      assert result.calls == %{target: 2}

      [extract, answer] = result.steps
      assert extract.inputs["question"] == "Where is the Eiffel Tower?"

      assert answer.inputs == %{
               "question" => "Where is the Eiffel Tower?",
               "facts" => @facts,
               "guidance" => "None."
             }

      [first, second] = Transport.requests(stub)
      assert Transport.prompt_text(first) =~ "The Eiffel Tower is in Paris."
      assert Transport.prompt_text(second) =~ "[[ ## facts ## ]]"
    end

    test "a failed second stage keeps the original cause and the completed first step" do
      stub = Transport.script([facts_reply(), {:text, "Paris, I think."}])

      assert {:error, %Error.Execution.Failed{cause: cause, result: result, step: "answer"}} =
               Tune.run(GroundedQA.new(), @inputs, model: model(stub))

      assert %Error.Output.Parse{reply: "Paris, I think."} = cause
      assert result.output == nil
      assert [%{name: "extract"}] = result.steps
      assert [%{name: "answer", role: :target, error: ^cause}] = result.failures
      assert result.calls == %{target: 2}
    end

    test "learned lessons reach the answering prompt through application code" do
      program = GroundedQA.new()
      {:ok, lessons} = Parameter.put_value(program.lessons, ["Cite every source you used."])
      {:ok, updated} = Tune.replace_parameters(program, %{"lessons" => lessons})

      stub = Transport.script([facts_reply(), answer_reply()])
      assert {:ok, _result} = Tune.run(updated, @inputs, model: model(stub))
      [_extract, answer] = Transport.requests(stub)
      assert Transport.prompt_text(answer) =~ "- Cite every source you used."

      assert program.lessons.value == []
    end
  end

  describe "parameter replacement" do
    setup do
      %{program: GroundedQA.new()}
    end

    test "rejects unknown names, kind changes, schema changes, and field changes", %{
      program: program
    } do
      {:ok, other_schema} = Parameter.new(schema: Zoi.string(), value: "x")

      {:ok, changed} =
        Predictor.new(
          signature: [inputs: [question: Zoi.string()], outputs: [facts: Zoi.string()]]
        )

      assert {:error, %Error.Invalid.Definition{}} =
               Tune.replace_parameters(program, %{"missing" => program.lessons})

      assert {:error, %Error.Invalid.Definition{}} =
               Tune.replace_parameters(program, %{"lessons" => program.extract})

      assert {:error, %Error.Invalid.Definition{}} =
               Tune.replace_parameters(program, %{"lessons" => other_schema})

      assert {:error, %Error.Invalid.Definition{}} =
               Tune.replace_parameters(program, %{"extract" => changed})
    end

    test "accepts new instructions and demos without changing the original", %{program: program} do
      {:ok, extract} = Predictor.put_instructions(program.extract, "Quote facts exactly.")
      {:ok, updated} = Tune.replace_parameters(program, %{"extract" => extract})

      assert updated.extract.signature.instructions == "Quote facts exactly."
      refute program.extract.signature.instructions == "Quote facts exactly."
    end

    test "a parameter value must match its schema", %{program: program} do
      assert {:error, %Error.Invalid.Definition{}} = Parameter.put_value(program.lessons, [1, 2])
    end
  end

  defmodule Branching do
    @behaviour Tune
    defstruct [:classify, :triage, :mode]

    def new(mode \\ :normal) do
      {:ok, classify} =
        Predictor.new(signature: [inputs: [text: Zoi.string()], outputs: [label: Zoi.string()]])

      {:ok, triage} =
        Predictor.new(
          signature: [inputs: [text: Zoi.string()], outputs: [priority: Zoi.string()]]
        )

      %__MODULE__{classify: classify, triage: triage, mode: mode}
    end

    @impl true
    def signature(_program) do
      {:ok, signature} =
        Tune.Signature.new(
          inputs: [text: Zoi.string()],
          outputs: [result: Zoi.string()]
        )

      signature
    end

    @impl true
    def parameters(program), do: %{"classify" => program.classify, "triage" => program.triage}

    @impl true
    def put_parameters(program, parameters),
      do: %{program | classify: parameters["classify"], triage: parameters["triage"]}

    @impl true
    def call(%{mode: :bad_return}, _inputs, _execution), do: :ok

    def call(%{mode: :wrong_kind}, _inputs, execution) do
      {:error, error} = Execution.value(execution, "classify")
      {:error, error, execution}
    end

    def call(%{mode: :bad_output}, _inputs, execution), do: {:ok, %{"result" => 1}, execution}

    def call(_program, inputs, execution) do
      with {:ok, %{"label" => label}, execution} <-
             Execution.predict(execution, "classify", inputs) do
        if label == "bug" do
          with {:ok, first, execution} <- Execution.predict(execution, "triage", inputs),
               {:ok, second, execution} <- Execution.predict(execution, "triage", inputs) do
            {:ok, %{"result" => first["priority"] <> "/" <> second["priority"]}, execution}
          end
        else
          {:ok, %{"result" => label}, execution}
        end
      end
    end
  end

  describe "explicit control flow" do
    test "branches and repeated calls are recorded in call order" do
      stub =
        Transport.script([
          Transport.chat(label: "bug"),
          Transport.chat(priority: "high"),
          Transport.chat(priority: "low")
        ])

      assert {:ok, result} = Tune.run(Branching.new(), %{text: "crash"}, model: model(stub))
      assert result.output == %{"result" => "high/low"}
      assert Enum.map(result.steps, & &1.name) == ["classify", "triage", "triage"]
    end

    test "the other branch makes only one call" do
      stub = Transport.script([Transport.chat(label: "question")])
      assert {:ok, result} = Tune.run(Branching.new(), %{text: "how?"}, model: model(stub))
      assert result.output == %{"result" => "question"}
      assert length(Transport.requests(stub)) == 1
    end

    test "program code that breaks the callback contract is reported" do
      stub = Transport.script([])

      assert {:error, %Error.Execution.Failed{cause: %Error.Execution.Callback{value: :ok}}} =
               Tune.run(Branching.new(:bad_return), %{text: "x"}, model: model(stub))
    end

    test "reading a predictor as a value is a kind error" do
      stub = Transport.script([])

      assert {:error, %Error.Execution.Failed{cause: %Error.Invalid.Definition{message: message}}} =
               Tune.run(Branching.new(:wrong_kind), %{text: "x"}, model: model(stub))

      assert message =~ "not a Tune.Parameter"
    end

    test "the final output is validated against the program signature" do
      stub = Transport.script([])

      assert {:error, %Error.Execution.Failed{cause: %Error.Output.Invalid{}}} =
               Tune.run(Branching.new(:bad_output), %{text: "x"}, model: model(stub))
    end
  end

  describe "managed limits" do
    test "an exhausted call allowance stops before the next dispatch" do
      stub = Transport.script([Transport.chat(label: "bug"), Transport.chat(priority: "high")])

      assert {:error,
              %Error.Execution.Failed{
                cause: %Error.Execution.LimitReached{limit: :model_calls},
                result: result
              }} =
               Tune.run(Branching.new(), %{text: "crash"},
                 model: model(stub),
                 max_model_calls: 1
               )

      assert result.calls == %{target: 1}
      assert length(Transport.requests(stub)) == 1
    end

    test "a zero allowance cannot start a request" do
      stub = Transport.script([Transport.chat(label: "bug")])

      assert {:error,
              %Error.Execution.Failed{cause: %Error.Execution.LimitReached{limit: :model_calls}}} =
               Tune.run(Branching.new(), %{text: "crash"},
                 model: model(stub),
                 max_model_calls: 0
               )

      assert Transport.requests(stub) == []
    end

    test "the step limit stops repeated calls" do
      stub = Transport.script([Transport.chat(label: "bug"), Transport.chat(priority: "high")])

      assert {:error,
              %Error.Execution.Failed{cause: %Error.Execution.LimitReached{limit: :steps}}} =
               Tune.run(Branching.new(), %{text: "crash"}, model: model(stub), max_steps: 2)

      assert length(Transport.requests(stub)) == 2
    end

    test "an expired deadline makes no request" do
      stub = Transport.script([Transport.chat(label: "bug")])

      assert {:error,
              %Error.Execution.Failed{cause: %Error.Execution.LimitReached{limit: :deadline}}} =
               Tune.run(Branching.new(), %{text: "crash"}, model: model(stub), timeout: 0)

      assert Transport.requests(stub) == []
    end

    test "remaining time decreases and is passed as the request deadline" do
      {:ok, execution} =
        Tune.new_execution(
          Branching.new(),
          elem(Tune.normalize_run_options(model: model(:unused), timeout: 10_000), 1)
        )

      first = Execution.remaining_ms(execution)
      Process.sleep(5)
      assert Execution.remaining_ms(execution) < first
      assert first <= 10_000
    end

    test "a missing role configuration is an error, not a silent fallback" do
      assert {:error, %Error.Invalid.Option{option: :role}} =
               Tune.run(Branching.new(), %{text: "x"}, model: model(:unused), role: :teacher)
    end
  end
end
