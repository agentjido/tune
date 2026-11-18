defmodule Tune.Examples.ExtractTicket do
  @moduledoc "Preview and extract the same typed ticket in three formats."

  alias Tune.Adapter
  alias Tune.Examples.Support.Offline
  alias Tune.Examples.Support.Transport

  def extract(adapter, opts \\ []) do
    {:ok, predictor} =
      Tune.Predictor.new(
        signature: [
          instructions: "Extract the ticket category and confidence.",
          inputs: [ticket: Zoi.string()],
          outputs: [label: Zoi.enum(["billing", "bug"]), confidence: Zoi.float()]
        ],
        demos: [
          %{
            inputs: %{ticket: "The app crashes when I open it"},
            outputs: %{label: "bug", confidence: 0.9}
          }
        ]
      )

    reply = Keyword.get(opts, :reply, reply(adapter))
    stub = Transport.script([reply])
    model = Offline.model(stub, adapter: adapter) ++ adapter_opts(adapter)
    input = %{ticket: "I was charged twice for my card purchase"}
    study = Tune.new(predictor, model: model)
    {:ok, preview} = Tune.preview(study, input)
    preview_calls = Transport.requests(stub)

    result =
      if Keyword.get(opts, :preview_only, false) do
        :preview_only
      else
        Tune.Runtime.run(predictor, input, model: model)
      end

    %{preview: preview, preview_calls: preview_calls, result: result}
  end

  defp reply(Adapter.Chat), do: Transport.chat(label: "billing", confidence: 0.8)
  defp reply(Adapter.JSON), do: {:text, ~s({"label":"billing","confidence":0.8})}

  defp reply(Adapter.XML),
    do: {:text, "<label>billing</label>\n<confidence>0.8</confidence>"}

  defp adapter_opts(Adapter.JSON), do: [adapter_options: [mode: :text]]
  defp adapter_opts(_), do: []
end
