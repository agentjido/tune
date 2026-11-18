alias Tune.Adapter
alias Tune.Examples.ExtractTicket

formats = [{"Chat", Adapter.Chat}, {"JSON", Adapter.JSON}, {"XML", Adapter.XML}]

case System.argv() do
  [] ->
    for {_name, adapter} <- formats do
      %{preview: preview, preview_calls: [], result: {:ok, prediction}} =
        ExtractTicket.extract(adapter)

      IO.puts("#{inspect(adapter)} typed output #{inspect(prediction.output)}")
      IO.puts("Preview messages #{length(preview.context.messages)} with no model calls")
    end

  ["--preview-only"] ->
    for {name, adapter} <- formats do
      %{preview: preview, preview_calls: [], result: :preview_only} =
        ExtractTicket.extract(adapter, preview_only: true)

      IO.puts("\n=== #{name} rendered prompt ===")

      for message <- preview.context.messages do
        body = Enum.map_join(message.content, "", & &1.text)
        IO.puts("\n[#{message.role}]\n#{body}")
      end
    end

    IO.puts("\nModel requests: 0")

  _ ->
    raise "Expected no arguments or --preview-only."
end
