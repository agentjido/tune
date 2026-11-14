# Local Ollama examples for Tune.
#
# Calls a local Ollama server only (no paid providers). Run from the package
# directory with Ollama serving the models below:
#
#     mix run examples/ollama_examples.exs
#
# Override models with OLLAMA_TARGET and OLLAMA_TEACHER. Results are
# measurements of this run on this machine only.

Code.require_file("grounded_qa.ex", __DIR__)
Code.require_file("comparison.ex", __DIR__)

defmodule OllamaExamples do
  alias Tune
  alias Tune.Adapter
  alias Tune.Examples.Comparison
  alias Tune.Examples.GroundedQA
  alias Tune.Optimizers.BootstrapFewShotWithRandomSearch
  alias Tune.Parameters
  alias Tune.Predictor

  @target System.get_env("OLLAMA_TARGET", "lfm3:latest")
  @teacher System.get_env("OLLAMA_TEACHER", "qwen3.8:27b")
  @request [temperature: 0.0, receive_timeout: 600_000]
  @limits [timeout: :infinity]

  def run do
    section("Models: target #{@target}, teacher #{@teacher}")
    classifier()
    qa_run()
    compare()
    reload()
  end

  defp model(id, adapter, options \\ []),
    do: [
      model: %{provider: :ollama, id: id},
      adapter: adapter,
      adapter_options: options,
      request_options: @request
    ]

  defp adapters,
    do: [
      {"chat", Adapter.Chat, []},
      {"json", Adapter.JSON, [mode: :text]},
      {"xml", Adapter.XML, []}
    ]

  defp classifier do
    section("1. One typed classifier through Chat, JSON, and XML")

    {:ok, predictor} =
      Predictor.new(
        signature: [
          instructions: "Classify the customer support ticket.",
          inputs: [ticket: Zoi.string(description: "Customer message")],
          outputs: [
            label: Zoi.enum(["billing", "bug", "feature_request"]),
            urgent: Zoi.boolean(description: "Whether the customer is blocked right now")
          ]
        ]
      )

    tickets = [
      "I was charged twice for my subscription this month.",
      "The app crashes every time I open the settings page and I can't work.",
      "It would be great if you supported dark mode."
    ]

    for {name, adapter, options} <- adapters(), ticket <- tickets do
      {micros, outcome} =
        :timer.tc(fn ->
          Tune.run(
            predictor,
            %{ticket: ticket},
            [model: model(@target, adapter, options)] ++ @limits
          )
        end)

      case outcome do
        {:ok, result} ->
          tokens = Tune.Result.token_totals(result).total

          IO.puts(
            "  #{pad(name)} #{inspect(result.output)}  (#{div(micros, 1000)} ms, #{tokens} tokens)"
          )

        {:error, error} ->
          IO.puts("  #{pad(name)} ERROR #{Exception.message(error)}")
      end
    end
  end

  defp qa_run do
    section("2. Two-step grounded QA with prompt inspection")
    program = GroundedQA.new()
    [row | _] = data()
    config = model(@teacher, Adapter.Chat)

    case Tune.run(program, row.inputs, [model: config] ++ @limits) do
      {:ok, result} ->
        for step <- result.steps do
          IO.puts("  step #{step.name}: #{inspect(step.outputs)}")
        end

        {:ok, cfg} = Tune.ModelConfig.new(config)
        answer = Enum.find(result.steps, &(&1.name == "answer"))
        {:ok, prepared} = Predictor.prepare(program.answer, answer.inputs, cfg)
        IO.puts("\n  Rendered answer prompt (user message):")

        prepared.context.messages
        |> List.last()
        |> Map.get(:content)
        |> Enum.map_join(& &1.text)
        |> indent()
        |> IO.puts()

      {:error, error} ->
        IO.puts("  ERROR #{Exception.message(error)}")
    end
  end

  defp compare do
    section("3. Baseline vs optimized grounded QA per target configuration")
    {train, rest} = Enum.split(data(), 3)
    {val, test} = Enum.split(rest, 2)

    rows =
      Comparison.run(
        &GroundedQA.new/0,
        Enum.map(adapters(), fn {name, adapter, options} ->
          {"#{@target} #{name}", model(@target, adapter, options)}
        end),
        optimizer:
          {BootstrapFewShotWithRandomSearch,
           accept_score: 1.0,
           num_candidate_programs: 1,
           max_bootstrapped_demos: 2,
           max_labeled_demos: 0},
        trainset: train,
        valset: val,
        testset: test,
        metric: &metric/2,
        failure_score: 0.0,
        teacher: model(@teacher, Adapter.Chat),
        max_model_calls: 120,
        timeout: :infinity,
        row_timeout: 900_000
      )

    IO.puts(Comparison.table(rows))

    for row <- rows do
      report = row.report

      IO.puts(
        "\n  #{row.name}: stop #{report.stop_reason}, calls #{inspect(report.calls)}, best #{inspect(report.best && report.best.label)}"
      )
    end

    Process.put(:comparison, rows)
  end

  defp reload do
    section("4. Artifact reload into fresh application code")

    case Enum.find(Process.get(:comparison, []), & &1.optimized) do
      nil ->
        IO.puts("  no optimized program to reload")

      row ->
        optimized = row.optimized_program

        {:ok, artifact} =
          Parameters.dump(optimized,
            provenance: Parameters.provenance(source: "ollama example", report: row.report)
          )

        {:ok, json} = Parameters.encode(artifact)
        path = Path.join(System.tmp_dir!(), "tune_qa_params.json")
        File.write!(path, json)
        {:ok, decoded} = Parameters.decode(File.read!(path))
        {:ok, loaded} = Parameters.apply(GroundedQA.new(), decoded)
        IO.puts("  wrote #{byte_size(json)} bytes to #{path}")

        IO.puts(
          "  reloaded demos: extract #{length(loaded.extract.demos)}, answer #{length(loaded.answer.demos)}"
        )

        IO.puts(
          "  reloaded equals optimized: #{Tune.parameters(loaded) == Tune.parameters(optimized)}"
        )

        [_, _, _, _, _ | test] = data()

        case Tune.run(
               loaded,
               hd(test).inputs,
               [model: model(@target, Adapter.Chat)] ++ @limits
             ) do
          {:ok, result} ->
            IO.puts("  reloaded program answer: #{inspect(result.output)}")

          {:error, error} ->
            IO.puts("  reloaded program run failed (retained error): #{Exception.message(error)}")
        end
    end
  end

  defp metric(example, result) do
    answer_ok =
      String.downcase(result.output["answer"]) =~ String.downcase(example.labels["answer"])

    sources_ok = example.labels["sources"] == Enum.sort(Enum.uniq(result.output["sources"]))
    score = if(answer_ok, do: 0.5, else: 0.0) + if(sources_ok, do: 0.5, else: 0.0)

    feedback =
      cond do
        score == 1.0 -> "correct"
        answer_ok -> "answer correct, but cite exactly #{inspect(example.labels["sources"])}"
        true -> "expected #{example.labels["answer"]}"
      end

    %{score: score, feedback: feedback}
  end

  defp data do
    p = fn id, text -> %{"id" => id, "text" => text} end

    row = fn q, passages, answer, sources ->
      %{inputs: %{context: passages, question: q}, labels: %{answer: answer, sources: sources}}
    end

    [
      row.(
        "Which city is the Eiffel Tower in?",
        [
          p.("p1", "The Eiffel Tower stands in Paris."),
          p.("p2", "Rome is the capital of Italy.")
        ],
        "Paris",
        ["p1"]
      ),
      row.(
        "Who wrote Pride and Prejudice?",
        [
          p.("b1", "Charles Dickens wrote Oliver Twist."),
          p.("b2", "Pride and Prejudice was written by Jane Austen.")
        ],
        "Jane Austen",
        ["b2"]
      ),
      row.(
        "What gas do plants absorb?",
        [
          p.("g1", "Plants absorb carbon dioxide during photosynthesis."),
          p.("g2", "Animals exhale carbon dioxide.")
        ],
        "carbon dioxide",
        ["g1"]
      ),
      row.(
        "How many legs does a spider have?",
        [p.("s1", "Insects have six legs."), p.("s2", "Spiders have eight legs.")],
        "eight",
        ["s2"]
      ),
      row.(
        "What is the largest planet?",
        [
          p.("j1", "Jupiter is the largest planet in the Solar System."),
          p.("j2", "Mars is called the red planet.")
        ],
        "Jupiter",
        ["j1"]
      ),
      row.(
        "At what temperature does water boil at sea level in Celsius?",
        [
          p.("w1", "Ice melts at 0 degrees Celsius."),
          p.("w2", "At sea level water boils at 100 degrees Celsius.")
        ],
        "100",
        ["w2"]
      ),
      row.(
        "Which metal is liquid at room temperature?",
        [
          p.("m1", "Mercury is a metal that is liquid at room temperature."),
          p.("m2", "Iron rusts in moist air.")
        ],
        "Mercury",
        ["m1"]
      ),
      row.(
        "What is the chemical symbol for gold?",
        [p.("c1", "Silver has the symbol Ag."), p.("c2", "Gold has the chemical symbol Au.")],
        "Au",
        ["c2"]
      )
    ]
  end

  defp section(title), do: IO.puts("\n== #{title}")
  defp pad(text), do: String.pad_trailing(text, 5)
  defp indent(text), do: text |> String.split("\n") |> Enum.map_join("\n", &("    " <> &1))
end

OllamaExamples.run()
