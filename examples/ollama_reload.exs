# Loads a saved parameter artifact into fresh GroundedQA code and runs it on
# local Ollama.
#
#     mix run examples/ollama_reload.exs [path]

Code.require_file("grounded_qa.ex", __DIR__)

alias Tune
alias Tune.Adapter
alias Tune.Examples.GroundedQA
alias Tune.Parameters

path = List.first(System.argv()) || Path.join(System.tmp_dir!(), "tune_qa_params.json")
target = System.get_env("OLLAMA_TARGET", "lfm3:latest")

{:ok, decoded} = Parameters.decode(File.read!(path))
{:ok, program} = Parameters.apply(GroundedQA.new(), decoded)

IO.puts(
  "loaded #{path}: extract demos #{length(program.extract.demos)}, answer demos #{length(program.answer.demos)}"
)

IO.puts(
  "provenance optimizer: #{decoded["provenance"]["optimizer"]}, calls #{inspect(decoded["provenance"]["calls"])}"
)

p = fn id, text -> %{"id" => id, "text" => text} end

questions = [
  {"Which metal is liquid at room temperature?",
   [
     p.("m1", "Mercury is a metal that is liquid at room temperature."),
     p.("m2", "Iron rusts in moist air.")
   ]},
  {"What is the chemical symbol for gold?",
   [p.("c1", "Silver has the symbol Ag."), p.("c2", "Gold has the chemical symbol Au.")]},
  {"What is the largest planet?",
   [
     p.("j1", "Jupiter is the largest planet in the Solar System."),
     p.("j2", "Mars is called the red planet.")
   ]}
]

model = [
  model: %{provider: :ollama, id: target},
  adapter: Adapter.Chat,
  request_options: [temperature: 0.0, receive_timeout: 600_000]
]

for {question, context} <- questions do
  case Tune.run(program, %{question: question, context: context},
         model: model,
         timeout: :infinity
       ) do
    {:ok, result} -> IO.puts("  #{question} -> #{inspect(result.output)}")
    {:error, error} -> IO.puts("  #{question} -> retained error: #{Exception.message(error)}")
  end
end
