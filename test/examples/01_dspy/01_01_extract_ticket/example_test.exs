defmodule Tune.Examples.ExtractTicketTest do
  use ExUnit.Case, async: true

  @moduletag :example

  alias Tune.Examples.ExtractTicket

  test "Chat, JSON, and XML preview without calls and produce equivalent typed results" do
    for adapter <- [Tune.Adapter.Chat, Tune.Adapter.JSON, Tune.Adapter.XML] do
      assert %{
               preview: %{context: %{messages: [_ | _]}},
               preview_calls: [],
               result:
                 {:ok,
                  %{output: %{"label" => "billing", "confidence" => 0.8}, calls: %{target: 1}}}
             } = ExtractTicket.extract(adapter)
    end
  end

  test "each adapter rejects a reply without the required typed fields" do
    for adapter <- [Tune.Adapter.Chat, Tune.Adapter.JSON, Tune.Adapter.XML] do
      assert %{preview_calls: [], result: {:error, %Tune.Error.Execution.Failed{}}} =
               ExtractTicket.extract(adapter, reply: {:text, "bad reply"})
    end
  end

  test "preview-only renders the demonstration and input without running the predictor" do
    for adapter <- [Tune.Adapter.Chat, Tune.Adapter.JSON, Tune.Adapter.XML] do
      assert %{
               preview: %{context: %{messages: messages}},
               preview_calls: [],
               result: :preview_only
             } = ExtractTicket.extract(adapter, preview_only: true)

      assert Enum.any?(messages, &(&1.role == :assistant))
      assert List.last(messages).role == :user
    end
  end
end
