# Prints raw Ollama replies for one prepared classifier request per adapter.
#
#     mix run examples/ollama_probe.exs

alias Tune.{Adapter, ModelConfig, Predictor}

model_id = System.get_env("OLLAMA_TARGET", "lfm3:latest")

{:ok, predictor} =
  Predictor.new(
    signature: [
      instructions: "Classify the customer support ticket.",
      inputs: [ticket: Zoi.string()],
      outputs: [label: Zoi.enum(["billing", "bug", "feature_request"]), urgent: Zoi.boolean()]
    ]
  )

for {adapter, options} <- [{Adapter.Chat, []}, {Adapter.JSON, [mode: :text]}, {Adapter.XML, []}] do
  {:ok, config} =
    ModelConfig.new(
      model: %{provider: :ollama, id: model_id},
      adapter: adapter,
      adapter_options: options,
      request_options: [temperature: 0.0, receive_timeout: 600_000]
    )

  {:ok, prepared} =
    Predictor.prepare(predictor, %{ticket: "I was charged twice this month."}, config)

  {micros, outcome} = :timer.tc(fn -> Predictor.execute(prepared, config, nil) end)

  case outcome do
    {:ok, response} ->
      IO.puts(
        "== #{inspect(adapter)} (#{div(micros, 1000)} ms, finish #{inspect(response.finish_reason)})"
      )

      IO.puts("text: " <> inspect(ReqLLM.Response.text(response)))
      IO.puts("thinking: " <> inspect(ReqLLM.Response.thinking(response) |> String.slice(0, 300)))
      IO.puts("usage: " <> inspect(response.usage))
      IO.puts("finish: " <> inspect(Predictor.finish(prepared, response) |> elem(0)))

    {:error, error} ->
      IO.puts("== #{inspect(adapter)} ERROR #{inspect(error)}")
  end
end
