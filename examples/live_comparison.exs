# Real-model grounded QA comparison.
#
# This script calls live, paid provider APIs. It never runs as part of the
# default checks. Run it only on purpose, with provider credentials in the
# environment that ReqLLM reads, for example:
#
#     TUNE_LIVE=1 \
#       mix run examples/live_comparison.exs -- \
#       --target openai:gpt-4o-mini --teacher openai:gpt-4o-mini --max-calls 200
#
# Every target is compared with the Chat, JSON (text mode), and XML adapters.
# Results are measurements of this run only.

unless System.get_env("TUNE_LIVE") == "1" do
  IO.puts("Refusing to call live providers. Set TUNE_LIVE=1 to run this example.")
  System.halt(1)
end

Code.require_file("grounded_qa.ex", __DIR__)
Code.require_file("comparison.ex", __DIR__)

alias Tune.Adapter
alias Tune.Examples.Comparison
alias Tune.Examples.GroundedQA
alias Tune.Optimizers.BootstrapFewShotWithRandomSearch

{opts, _rest, _invalid} =
  OptionParser.parse(Enum.reject(System.argv(), &(&1 == "--")),
    strict: [target: :keep, teacher: :string, max_calls: :integer, seed: :integer]
  )

targets = Keyword.get_values(opts, :target)

if targets == [] do
  IO.puts("Give at least one --target model.")
  System.halt(1)
end

teacher = Keyword.get(opts, :teacher) || hd(targets)

passage = fn id, text -> %{"id" => id, "text" => text} end

row = fn question, passages, answer, sources ->
  %{inputs: %{context: passages, question: question}, labels: %{answer: answer, sources: sources}}
end

data = [
  row.(
    "Which city is the Eiffel Tower in?",
    [passage.("p1", "The Eiffel Tower stands in Paris."), passage.("p2", "Rome is in Italy.")],
    "Paris",
    ["p1"]
  ),
  row.(
    "What is the boiling point of water at sea level in Celsius?",
    [
      passage.("w1", "At sea level water boils at 100 degrees Celsius."),
      passage.("w2", "Ice melts at 0 degrees.")
    ],
    "100",
    ["w1"]
  ),
  row.(
    "Who wrote Pride and Prejudice?",
    [
      passage.("b1", "Pride and Prejudice was written by Jane Austen."),
      passage.("b2", "Dickens wrote Oliver Twist.")
    ],
    "Jane Austen",
    ["b1"]
  ),
  row.(
    "What gas do plants absorb?",
    [
      passage.("g1", "Plants absorb carbon dioxide during photosynthesis."),
      passage.("g2", "Humans exhale it.")
    ],
    "carbon dioxide",
    ["g1"]
  ),
  row.(
    "How many legs does a spider have?",
    [passage.("s1", "Spiders have eight legs."), passage.("s2", "Insects have six legs.")],
    "eight",
    ["s1"]
  ),
  row.(
    "What is the largest planet?",
    [
      passage.("j1", "Jupiter is the largest planet in the Solar System."),
      passage.("j2", "Mars is red.")
    ],
    "Jupiter",
    ["j1"]
  )
]

{trainset, rest} = Enum.split(data, 2)
{valset, testset} = Enum.split(rest, 2)

metric = fn example, result ->
  answer_ok =
    String.downcase(result.output["answer"]) =~ String.downcase(example.labels["answer"])

  sources_ok = Enum.all?(example.labels["sources"], &(&1 in result.output["sources"]))
  score = if(answer_ok, do: 0.7, else: 0.0) + if(sources_ok, do: 0.3, else: 0.0)

  %{
    score: score,
    feedback:
      if(score == 1.0,
        do: "correct",
        else: "expected #{example.labels["answer"]} citing #{inspect(example.labels["sources"])}"
      )
  }
end

adapters = [
  {"chat", Adapter.Chat, []},
  {"json", Adapter.JSON, [mode: :text]},
  {"xml", Adapter.XML, []}
]

configs =
  for model <- targets, {name, adapter, adapter_options} <- adapters do
    {"#{model} #{name}",
     [
       model: model,
       adapter: adapter,
       adapter_options: adapter_options,
       request_options: [temperature: 0.0, receive_timeout: 600_000]
     ]}
  end

rows =
  Comparison.run(&GroundedQA.new/0, configs,
    optimizer:
      {BootstrapFewShotWithRandomSearch,
       accept_score: 1.0, num_candidate_programs: 2, max_bootstrapped_demos: 2},
    trainset: trainset,
    valset: valset,
    testset: testset,
    metric: metric,
    failure_score: 0.0,
    teacher: [
      model: teacher,
      adapter: Adapter.Chat,
      request_options: [temperature: 0.0, receive_timeout: 600_000]
    ],
    max_model_calls: Keyword.get(opts, :max_calls, 200),
    seed: Keyword.get(opts, :seed, 0),
    timeout: :infinity,
    row_timeout: 900_000
  )

IO.puts(Comparison.table(rows))
