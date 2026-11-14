defmodule Tune.Optimizers.ExampleLearningTest do
  use ExUnit.Case, async: true

  alias Tune
  alias Tune.Adapter
  alias Tune.Error
  alias Tune.Examples.GroundedQA
  alias Tune.Execution
  alias Tune.Optimizer.Report
  alias Tune.Optimizers.BootstrapFewShot
  alias Tune.Optimizers.LabeledFewShot
  alias Tune.Predictor
  alias Tune.TestSupport.QAWorld
  alias Tune.TestSupport.Transport

  defp config(stub),
    do: [
      model: Transport.model(),
      adapter: Adapter.Chat,
      request_options: Transport.request_options(stub)
    ]

  defp classifier do
    {:ok, predictor} =
      Predictor.new(
        signature: [
          inputs: [ticket: Zoi.string()],
          outputs: [label: Zoi.enum(["billing", "bug", "other"])]
        ]
      )

    predictor
  end

  defp tickets(n) do
    for i <- 1..n do
      %{
        inputs: %{ticket: "ticket #{i}"},
        labels: %{label: Enum.at(["billing", "bug", "other"], rem(i, 3))}
      }
    end
  end

  describe "LabeledFewShot" do
    test "selects complete labeled rows without model calls, reproducibly by seed" do
      stub = Transport.script([])
      opts = [optimizer: {LabeledFewShot, k: 3}, trainset: tickets(10), model: config(stub)]

      assert {:ok, first, %Report{} = report} =
               Tune.optimize(classifier(), Keyword.put(opts, :seed, 7))

      assert {:ok, again, _} = Tune.optimize(classifier(), Keyword.put(opts, :seed, 7))
      assert {:ok, other, _} = Tune.optimize(classifier(), Keyword.put(opts, :seed, 8))

      assert length(first.demos) == 3
      assert first.demos == again.demos
      refute first.demos == other.demos
      assert report.complete?
      assert Report.total_calls(report) == 0
      assert report.best == nil
      assert Transport.requests(stub) == []
    end

    test "takes the first k rows when sampling is off and skips incomplete rows" do
      rows = [%{inputs: %{ticket: "no label"}} | tickets(3)]

      assert {:ok, program, _} =
               Tune.optimize(classifier(),
                 optimizer: {LabeledFewShot, k: 2, sample: false},
                 trainset: rows,
                 model: config(:unused)
               )

      assert Enum.map(program.demos, & &1.inputs["ticket"]) == ["ticket 1", "ticket 2"]
    end

    test "rejects test data, validation-free misuse, and unknown options" do
      assert {:error, %Error.Invalid.Option{option: :testset}} =
               Tune.optimize(classifier(),
                 optimizer: LabeledFewShot,
                 trainset: tickets(2),
                 testset: tickets(1),
                 model: config(:unused)
               )

      assert {:error, %Error.Invalid.Option{option: :trainset}} =
               Tune.optimize(classifier(), optimizer: LabeledFewShot, model: config(:unused))

      assert {:error, %Error.Invalid.Option{option: :kk}} =
               Tune.optimize(classifier(),
                 optimizer: {LabeledFewShot, kk: 1},
                 trainset: tickets(2),
                 model: config(:unused)
               )
    end
  end

  describe "BootstrapFewShot on grounded QA" do
    setup do
      rows =
        QAWorld.rows([
          {"What is Alpha?", "alpha", "first"},
          {"What is Beta?", "beta", "second"},
          {"What is Gamma?", "gamma", "third"}
        ])

      %{rows: rows}
    end

    test "successful teacher traces supply demos for both predictors", %{rows: rows} do
      target = QAWorld.stub()
      teacher = QAWorld.stub()

      assert {:ok, program, report} =
               Tune.optimize(GroundedQA.new(),
                 optimizer: {BootstrapFewShot, accept_score: 1.0, max_bootstrapped_demos: 2},
                 trainset: rows,
                 metric: &QAWorld.metric/2,
                 model: config(target),
                 teacher: config(teacher),
                 max_model_calls: 20
               )

      assert report.complete?
      assert report.calls == %{teacher: 4}
      assert Transport.requests(target) == []
      assert length(Transport.requests(teacher)) == 4

      assert [first_extract, _] = program.extract.demos
      assert first_extract.inputs["question"] == "What is Alpha?"
      assert [%{"source" => "alpha-1"}] = first_extract.outputs["facts"]

      assert [first_answer, _] = program.answer.demos
      assert first_answer.outputs == %{"answer" => "first", "sources" => ["alpha-1"]}
      assert first_answer.inputs["guidance"] == "None."

      assert report.notes.bootstrapped == %{"answer" => 2, "extract" => 2}
    end

    test "a failed answer step cannot supply the extraction trace", %{rows: rows} do
      teacher = QAWorld.stub(overrides: %{"What is Alpha?" => :fail_answer})

      assert {:ok, program, report} =
               Tune.optimize(GroundedQA.new(),
                 optimizer: {BootstrapFewShot, accept_score: 1.0, max_bootstrapped_demos: 3},
                 trainset: rows,
                 metric: &QAWorld.metric/2,
                 model: config(:unused),
                 teacher: config(teacher),
                 max_model_calls: 20
               )

      questions = Enum.map(program.extract.demos, & &1.inputs["question"])
      refute "What is Alpha?" in questions
      assert questions == ["What is Beta?", "What is Gamma?"]
      assert report.notes.accepted_rows == 2
    end

    test "a low score rejects a complete trajectory", %{rows: rows} do
      teacher = QAWorld.stub(overrides: %{"What is Beta?" => {:answer, "wrong"}})

      assert {:ok, program, _report} =
               Tune.optimize(GroundedQA.new(),
                 optimizer: {BootstrapFewShot, accept_score: 1.0},
                 trainset: rows,
                 metric: &QAWorld.metric/2,
                 model: config(:unused),
                 teacher: config(teacher),
                 max_model_calls: 20
               )

      refute "What is Beta?" in Enum.map(program.answer.demos, & &1.inputs["question"])
    end

    test "a call limit during the build is an error with a partial report", %{rows: rows} do
      teacher = QAWorld.stub()

      assert {:error, %Error.Optimization.Failed{report: report, cause: cause}} =
               Tune.optimize(GroundedQA.new(),
                 optimizer: {BootstrapFewShot, accept_score: 1.0, max_bootstrapped_demos: 3},
                 trainset: rows,
                 metric: &QAWorld.metric/2,
                 model: config(:unused),
                 teacher: config(teacher),
                 max_model_calls: 3
               )

      assert %Error.Execution.LimitReached{limit: :model_calls} = cause
      refute report.complete?
      assert report.stop_reason == :budget_exhausted
      assert report.calls == %{teacher: 3}
      assert length(Transport.requests(teacher)) == 3
      assert report.notes.bootstrapped["extract"] == 1
    end

    test "a zero budget starts no request", %{rows: rows} do
      teacher = QAWorld.stub()

      assert {:error, %Error.Optimization.Failed{report: %{calls: calls}}} =
               Tune.optimize(GroundedQA.new(),
                 optimizer: {BootstrapFewShot, accept_score: 1.0},
                 trainset: rows,
                 metric: &QAWorld.metric/2,
                 model: config(:unused),
                 teacher: config(teacher),
                 max_model_calls: 0
               )

      assert calls == %{}
      assert Transport.requests(teacher) == []
    end

    test "explicit roles, limits, and thresholds are required", %{rows: rows} do
      base = [trainset: rows, metric: &QAWorld.metric/2, model: config(:unused)]

      assert {:error, %Error.Invalid.Option{option: :teacher}} =
               Tune.optimize(
                 GroundedQA.new(),
                 [optimizer: {BootstrapFewShot, accept_score: 1.0}, max_model_calls: 5] ++ base
               )

      assert {:error, %Error.Invalid.Option{option: :max_model_calls}} =
               Tune.optimize(
                 GroundedQA.new(),
                 [optimizer: {BootstrapFewShot, accept_score: 1.0}, teacher: config(:unused)] ++
                   base
               )

      assert {:error,
              %Error.Optimization.Failed{cause: %Error.Invalid.Option{option: :accept_score}}} =
               Tune.optimize(
                 GroundedQA.new(),
                 [optimizer: BootstrapFewShot, teacher: config(:unused), max_model_calls: 5] ++
                   base
               )
    end

    test "exact duplicate training rows are removed once and counted", %{rows: rows} do
      teacher = QAWorld.stub()

      assert {:ok, _program, report} =
               Tune.optimize(GroundedQA.new(),
                 optimizer: {BootstrapFewShot, accept_score: 1.0, max_bootstrapped_demos: 5},
                 trainset: rows ++ [hd(rows)],
                 metric: &QAWorld.metric/2,
                 model: config(:unused),
                 teacher: config(teacher),
                 max_model_calls: 20
               )

      assert report.notes.train_duplicates_removed == 1
      assert report.datasets.train == 3
    end
  end

  describe "teacher demonstrations" do
    test "the current row's labeled demo is removed before the teacher sees it" do
      teacher = Transport.respond_with(fn _body -> Transport.chat(label: "bug") end)

      assert {:ok, _program, _report} =
               Tune.optimize(classifier(),
                 optimizer: {BootstrapFewShot, max_bootstrapped_demos: 3, max_labeled_demos: 3},
                 trainset: tickets(3),
                 model: config(:unused),
                 teacher: config(teacher),
                 max_model_calls: 10
               )

      for {body, i} <- Enum.with_index(Transport.requests(teacher), 1) do
        prompt = Transport.prompt_text(body)
        assert length(String.split(prompt, "ticket #{i}\n")) == 2
        assert prompt =~ "ticket #{rem(i, 3) + 1}"
      end
    end
  end

  defmodule Repeating do
    @behaviour Tune
    defstruct [:step]

    def new do
      {:ok, step} =
        Predictor.new(
          signature: [inputs: [text: Zoi.string()], outputs: [text_out: Zoi.string()]]
        )

      %__MODULE__{step: step}
    end

    @impl true
    def signature(_),
      do:
        elem(
          Tune.Signature.new(
            inputs: [text: Zoi.string()],
            outputs: [text_out: Zoi.string()]
          ),
          1
        )

    @impl true
    def parameters(program), do: %{"step" => program.step}
    @impl true
    def put_parameters(program, parameters), do: %{program | step: parameters["step"]}
    @impl true
    def call(_program, inputs, execution) do
      with {:ok, first, execution} <- Execution.predict(execution, "step", inputs) do
        Execution.predict(execution, "step", %{"text" => first["text_out"]})
      end
    end
  end

  test "a repeated predictor contributes its final successful call" do
    teacher =
      Transport.respond_with(fn body ->
        text = Transport.last_user_text(body)

        if text =~ "draft",
          do: Transport.chat(text_out: "final"),
          else: Transport.chat(text_out: "draft")
      end)

    assert {:ok, program, _report} =
             Tune.optimize(Repeating.new(),
               optimizer: {BootstrapFewShot, max_bootstrapped_demos: 1, max_labeled_demos: 0},
               trainset: [%{inputs: %{text: "start"}}],
               model: config(:unused),
               teacher: config(teacher),
               max_model_calls: 5
             )

    assert [%{inputs: %{"text" => "draft"}, outputs: %{"text_out" => "final"}}] =
             program.step.demos
  end
end
