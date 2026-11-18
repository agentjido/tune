defmodule Tune.Examples.Support.Offline do
  @moduledoc false

  alias Tune.Examples.Support.Transport

  def model(stub, options \\ []) do
    Keyword.merge(
      [
        model: Transport.model(),
        adapter: Tune.Adapter.Chat,
        request_options: Transport.request_options(stub)
      ],
      options
    )
  end

  def judge(stub) do
    [
      model: Transport.model(),
      request_options:
        Transport.request_options(stub, openai_structured_output_mode: :tool_strict)
    ]
  end

  def field(text, name) do
    case Regex.run(~r/\[\[ ## #{name} ## \]\]\n(.*?)(?=\n\n\[\[ ## |\n\nRespond with|\z)/s, text) do
      [_, value] -> value
      nil -> nil
    end
  end
end
