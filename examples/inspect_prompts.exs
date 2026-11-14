# Run with: mix run examples/inspect_prompts.exs
# This example makes no model requests. Replies are supplied below.

alias ReqLLM.Context
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
  {"Chat", Adapter.Chat, [],
   "[[ ## label ## ]]\nbilling\n\n[[ ## urgent ## ]]\nfalse\n\n[[ ## completed ## ]]"},
  {"JSON", Adapter.JSON, [mode: :text], ~s({"label":"billing","urgent":false})},
  {"XML", Adapter.XML, [], "<label>\nbilling\n</label>\n\n<urgent>\nfalse\n</urgent>"}
]

for {name, adapter, options, reply} <- formats do
  {:ok, model} =
    ModelConfig.new(
      model: "openai:gpt-4o-mini",
      adapter: adapter,
      adapter_options: options
    )

  {:ok, prepared} =
    Predictor.prepare(predictor, %{ticket: "I was charged twice this month."}, model)

  IO.puts("\n=== #{name}: rendered prompt ===")

  for message <- prepared.context.messages do
    IO.puts("\n[#{message.role}]")
    IO.puts(Enum.map_join(message.content, "", & &1.text))
  end

  response = %ReqLLM.Response{
    id: "supplied-example-reply",
    model: model.model_id,
    context: prepared.context,
    message: Context.assistant(reply),
    finish_reason: :stop
  }

  {:ok, step} = Predictor.finish(prepared, response)
  IO.puts("Validated supplied reply: #{inspect(step.outputs)}")
end

IO.puts("\nModel requests: 0. Change the instructions or adapter to inspect another prompt.")
