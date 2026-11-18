defmodule Tune.Optimizers.ReflectiveTest do
  use ExUnit.Case, async: true

  alias Tune
  alias Tune.Adapter
  alias Tune.Examples.Support.GroundedQA
  alias Tune.Examples.Support.QAWorld
  alias Tune.Examples.Support.Transport
  alias Tune.Execution
  alias Tune.Optimizers.Anything
  alias Tune.Optimizers.GEPA
  alias Tune.Optimizers.Reflective
  alias Tune.Parameter
  alias Tune.Predictor

  defp config(stub),
    do: [
      model: Transport.model(),
      adapter: Adapter.Chat,
      request_options: Transport.request_options(stub)
    ]

  defp field(text, name) do
    case Regex.run(~r/\[\[ ## #{name} ## \]\]\n(.*?)(?=\n\n\[\[ ## |\n\nRespond with|\z)/s, text) do
      [_, value] -> value
      nil -> nil
    end
  end

  defp qa_target do
    Transport.respond_with(fn body ->
      prompt = Transport.prompt_text(body)
      user = Transport.last_user_text(body)

      if user =~ "[[ ## context ## ]]" do
        context = JSON.decode!(field(user, "context"))
        [passage | _] = context
        prefix = if prompt =~ "Quote", do: "QUOTED ", else: ""
        Transport.chat(facts: [%{"text" => prefix <> passage["text"], "source" => passage["id"]}])
      else
        question = field(user, "question")
        [fact] = JSON.decode!(field(user, "facts"))
        [_, answer] = Regex.run(~r/: (.*)\.$/, fact["text"])

        cond do
          question =~ ~r/Alpha|Gamma/ and fact["text"] =~ "QUOTED" ->
            Transport.chat(answer: answer, sources: [fact["source"]])

          question =~ ~r/Beta|Delta/ and prompt =~ "passage id" ->
            Transport.chat(answer: answer, sources: [fact["source"]])

          true ->
            Transport.chat(answer: "unknown", sources: [])
        end
      end
    end)
  end

  defp reflector do
    Transport.respond_with(fn body ->
      prompt = Transport.prompt_text(body)

      if prompt =~ "Outputs: `facts`",
        do: Transport.chat(new_instruction: "Quote the passages exactly."),
        else: Transport.chat(new_instruction: "Cite the passage id and answer.")
    end)
  end

  defp qa_rows(prefix),
    do:
      QAWorld.rows([
        {"What is Alpha#{prefix}?", "alpha#{prefix}", "first"},
        {"What is Beta#{prefix}?", "beta#{prefix}", "second"}
      ])

  defp gepa(opts, reflector \\ reflector(), metric \\ &QAWorld.metric/2) do
    {seed, opts} = Keyword.pop(opts, :seed, 0)

    Tune.TestSupport.Search.run(GroundedQA.new(),
      search: {GEPA, Keyword.merge([max_iterations: 6, minibatch_size: 2, merge_every: 3], opts)},
      train:
        qa_rows(" train") ++
          QAWorld.rows([
            {"What is Gamma?", "gamma", "third"},
            {"What is Delta?", "delta", "fourth"}
          ]),
      validation: qa_rows(""),
      metric: metric,
      model: config(qa_target()),
      proposal: config(reflector),
      model_calls: 400,
      seed: seed
    )
  end

  describe "GEPA" do
    test "metric feedback reaches reflection and improvements are kept with lineage" do
      reflector = reflector()
      assert {:ok, best, report} = gepa([use_merge: false], reflector)

      assert report.best.evaluation.selected_score == 1.0
      assert best.answer.signature.instructions == "Cite the passage id and answer."
      assert best.extract.signature.instructions == "Quote the passages exactly."

      [first | _] = Transport.requests(reflector)
      assert Transport.prompt_text(first) =~ "feedback: expected"
      assert Transport.prompt_text(first) =~ "score: 0.0"

      pool = report.metadata.notes.pool
      assert hd(pool).parents == []
      assert Enum.all?(tl(pool), &(&1.parents != []))
    end

    test "complementary children with a common ancestor are merged" do
      results = for seed <- 0..5, do: gepa(max_iterations: 6, merge_every: 3, seed: seed)
      assert Enum.all?(results, &match?({:ok, _, _}, &1))

      merges =
        for {:ok, _best, report} <- results,
            record <- report.metadata.notes.iterations,
            record.kind == :merge,
            do: {record, report}

      assert merges != []

      for {record, report} <- merges do
        [a, b] = record.parents
        merged = Enum.find(report.history, &(&1.lineage[:merged_from] == [a, b]))
        assert merged.metadata.ancestor == record.ancestor
        assert merged.evaluation.selected_score == 1.0
      end
    end

    test "score-only metrics still drive reflection" do
      metric = fn example, output ->
        if output["answer"] == example.expected["answer"], do: 1, else: 0
      end

      assert {:ok, _best, report} = gepa([use_merge: false], reflector(), metric)
      assert report.best.evaluation.selected_score == 1.0
    end

    test "per-row strengths shape the Pareto frontier" do
      pool = [
        %{id: 0, row_scores: %{"a" => 0.0, "b" => 0.0}},
        %{id: 1, row_scores: %{"a" => 1.0, "b" => 0.0}},
        %{id: 2, row_scores: %{"a" => 0.0, "b" => 1.0}},
        %{id: 3, row_scores: %{"a" => 0.5, "b" => 0.5}}
      ]

      assert Reflective.frontier_counts(pool) == %{1 => 1, 2 => 1}
    end

    test "a child that does not beat its parent on the minibatch is not validated" do
      same = Transport.respond_with(fn _ -> Transport.chat(new_instruction: "Try harder.") end)
      assert {:ok, best, report} = gepa([use_merge: false, max_iterations: 2], same)
      assert best == GroundedQA.new()
      assert Enum.all?(report.metadata.notes.iterations, &(not &1.accepted?))
      assert [baseline] = report.history
      assert baseline.metadata.label == "baseline"
    end

    test "the call limit holds during reflection and validation" do
      assert {:ok, _best, report} =
               Tune.TestSupport.Search.run(GroundedQA.new(),
                 search: {GEPA, max_iterations: 10, minibatch_size: 2},
                 train: qa_rows(" train"),
                 validation: qa_rows(""),
                 metric: &QAWorld.metric/2,
                 model: config(qa_target()),
                 proposal: config(reflector()),
                 model_calls: 13
               )

      refute report.complete?
      assert report.calls |> Map.values() |> Enum.sum() <= 13
    end
  end

  defmodule Styled do
    @behaviour Tune.Program
    defstruct [:root, :style, :other]

    def new(schema \\ Zoi.string(), value \\ "Be casual.") do
      {:ok, root} =
        Predictor.new(
          signature: [
            inputs: [ticket: Zoi.string(), style: Zoi.string()],
            outputs: [reply: Zoi.string()]
          ]
        )

      {:ok, style} = Parameter.new(schema: schema, value: value, description: "Reply style guide")
      {:ok, other} = Parameter.new(schema: Zoi.array(Zoi.string()), value: ["keep"])
      %__MODULE__{root: root, style: style, other: other}
    end

    @impl true
    def signature(_),
      do:
        elem(
          Tune.Signature.new(
            inputs: [ticket: Zoi.string()],
            outputs: [reply: Zoi.string()]
          ),
          1
        )

    @impl true
    def parameters(p), do: %{"root" => p.root, "style" => p.style, "other" => p.other}
    @impl true
    def put_parameters(p, params),
      do: %{p | root: params["root"], style: params["style"], other: params["other"]}

    @impl true
    def call(_p, inputs, execution) do
      {:ok, style} = Execution.value(execution, "style")
      text = if is_binary(style), do: style, else: JSON.encode!(style)
      Execution.predict(execution, "root", Map.put(inputs, "style", text))
    end
  end

  defp styled_target do
    Transport.respond_with(fn body ->
      user = Transport.last_user_text(body)
      Transport.chat(reply: if(user =~ "formal", do: "Dear customer", else: "hey"))
    end)
  end

  defp polite(example, output) do
    if output["reply"] == example.expected["reply"],
      do: %{score: 1.0, feedback: "good"},
      else: %{score: 0.0, feedback: "the reply must be formal"}
  end

  defp anything(program, proposals, opts \\ []) do
    {:ok, agent} = Agent.start_link(fn -> proposals end)

    proposer =
      Transport.respond_with(fn _ ->
        text = Agent.get_and_update(agent, fn [next | rest] -> {next, rest ++ [next]} end)
        Transport.chat(new_value: text)
      end)

    rows = fn prefix ->
      for i <- 1..2,
          do: %{input: %{ticket: "#{prefix} #{i}"}, expected: %{reply: "Dear customer"}}
    end

    result =
      Tune.TestSupport.Search.run(program,
        search:
          {Anything,
           Keyword.merge([parameter: "style", max_iterations: 3, minibatch_size: 2], opts)},
        train: rows.("train"),
        validation: rows.("val"),
        metric: &polite/2,
        model: config(styled_target()),
        proposal: config(proposer),
        model_calls: 100
      )

    {result, proposer}
  end

  describe "Optimize.Anything" do
    test "optimizes a text value used by application code, leaving other parameters alone" do
      {{:ok, best, report}, proposer} = anything(Styled.new(), ["Be formal and polite."])
      assert best.style.value == "Be formal and polite."
      assert best.other.value == ["keep"]
      assert best.root == Styled.new().root
      assert report.best.evaluation.selected_score == 1.0

      [request | _] = Transport.requests(proposer)
      assert Transport.prompt_text(request) =~ "Reply style guide"
      assert Transport.prompt_text(request) =~ "the reply must be formal"
    end

    test "optimizes a nested JSON value and enforces its schema on every proposal" do
      schema = Zoi.object(%{"tone" => Zoi.string(), "max_words" => Zoi.integer()})
      program = Styled.new(schema, %{"tone" => "casual", "max_words" => 50})

      {{:ok, best, report}, _} =
        anything(program, [~s({"tone": 3}), "not json", ~s({"tone": "formal", "max_words": 20})],
          max_iterations: 4
        )

      assert best.style.value == %{"tone" => "formal", "max_words" => 20}
      rejected = Enum.filter(report.metadata.notes.iterations, &(&1.child_minibatch == nil))
      assert length(rejected) >= 2
    end

    test "the optimized value reloads into the same application code" do
      {{:ok, _best, report}, _} = anything(Styled.new(), ["Be formal."])
      {:ok, artifact} = Tune.dump(report)
      {:ok, loaded} = Tune.load(artifact, Styled.new())
      assert loaded.style.value == "Be formal."
    end

    test "the parameter must be a declared value" do
      {{:error, error}, _} = anything(Styled.new(), ["x"], parameter: "root")
      assert %Tune.Error.Optimization.Failed{} = error
    end
  end
end
