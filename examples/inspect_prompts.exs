# Run with: mix run examples/inspect_prompts.exs
# This example makes no model requests.

alias Tune.Adapter
alias Tune.ModelConfig
alias Tune.Predictor

{:ok, predictor} =
  Predictor.new(
    signature: [
      instructions: "Classify the support ticket. Mark it urgent if the customer cannot work.",
      inputs: [ticket: Zoi.string()],
      outputs: [label: Zoi.enum(["billing", "bug", "other"]), urgent: Zoi.boolean()]
    ],
    demos: [
      %{
        inputs: %{ticket: "The app crashes and I cannot work."},
        outputs: %{label: "bug", urgent: true}
      }
    ]
  )

formats = [
  {"Chat", Adapter.Chat, []},
  {"JSON", Adapter.JSON, [mode: :text]},
  {"XML", Adapter.XML, []}
]

for {name, adapter, options} <- formats do
  {:ok, model} =
    ModelConfig.new(
      model: "openai:gpt-4o-mini",
      adapter: adapter,
      adapter_options: options
    )

  {:ok, prepared} =
    predictor
    |> Tune.new(model: model)
    |> Tune.preview(%{ticket: "I was charged twice this month."})

  IO.puts("\n=== #{name}: rendered prompt ===")

  for message <- prepared.context.messages do
    IO.puts("\n[#{message.role}]")
    IO.puts(Enum.map_join(message.content, "", & &1.text))
  end
end

IO.puts("\nModel requests: 0. Change the instructions or adapter to inspect another prompt.")
