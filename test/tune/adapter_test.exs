defmodule Tune.AdapterTest do
  use ExUnit.Case, async: true

  alias Tune.Adapter
  alias Tune.Demo
  alias Tune.Error
  alias Tune.Signature

  @fixtures Path.expand("../fixtures/prompts", __DIR__)
  @trailing_comma ~s({"label": "bug", "confidence": 1.0, "tags": [],})

  setup do
    {:ok, signature} =
      Signature.new(
        instructions: "Classify the support ticket.",
        inputs: [ticket: Zoi.string(description: "Customer message")],
        outputs: [
          label: Zoi.enum(["billing", "bug", "other"]),
          confidence: Zoi.float(),
          tags: Zoi.array(Zoi.string())
        ]
      )

    {:ok, demo} =
      Demo.new(signature, %{
        inputs: %{ticket: "App crashes on launch"},
        outputs: %{label: "bug", confidence: 0.9, tags: ["crash"]}
      })

    %{signature: signature, demo: demo, inputs: %{"ticket" => "I was charged twice"}}
  end

  describe "golden prompts" do
    test "Chat renders DSPy-style markers, demonstrations, and the response hint", ctx do
      assert {:ok, %{context: context, output: output}} =
               Adapter.Chat.render(ctx.signature, [ctx.demo], ctx.inputs, [])

      assert output == ReqLLM.Output.text()
      assert transcript(context) == File.read!(Path.join(@fixtures, "chat_classifier.txt"))
    end

    test "JSON renders an object skeleton and ordered demonstration objects", ctx do
      assert {:ok, %{context: context, output: output}} =
               Adapter.JSON.render(ctx.signature, [ctx.demo], ctx.inputs, mode: :text)

      assert output == ReqLLM.Output.text()
      assert transcript(context) == File.read!(Path.join(@fixtures, "json_classifier.txt"))
    end

    test "structured JSON uses the same messages and requests the output schema", ctx do
      {:ok, text} = Adapter.JSON.render(ctx.signature, [ctx.demo], ctx.inputs, mode: :text)

      {:ok, structured} =
        Adapter.JSON.render(ctx.signature, [ctx.demo], ctx.inputs, mode: :structured)

      assert structured.context == text.context
      assert %ReqLLM.Output{type: :object, schema: schema} = structured.output
      assert schema == ctx.signature.output_schema
    end
  end

  describe "equivalent replies" do
    test "every format yields the same typed output map", ctx do
      expected = %{"label" => "billing", "confidence" => 0.75, "tags" => ["refund", "card"]}

      replies = [
        {Adapter.Chat, [],
         {:text,
          "Sure.\n[[ ## label ## ]]\nbilling\n\n[[ ## confidence ## ]]\n0.75\n\n[[ ## tags ## ]]\n[\"refund\", \"card\"]\n\n[[ ## completed ## ]]"}},
        {Adapter.JSON, [mode: :text],
         {:text, ~s({"label": "billing", "confidence": 0.75, "tags": ["refund", "card"]})}},
        {Adapter.JSON, [mode: :text],
         {:text,
          "```json\n{\"tags\": [\"refund\", \"card\"], \"confidence\": 0.75, \"label\": \"billing\"}\n```"}},
        {Adapter.JSON, [mode: :structured], {:object, expected}}
      ]

      for {adapter, opts, reply} <- replies do
        assert {:ok, parsed} = adapter.parse(ctx.signature, reply, opts)
        assert {:ok, ^expected} = Signature.validate_outputs(ctx.signature, parsed)
      end
    end
  end

  describe "Chat parsing" do
    test "rejects a missing output marker", ctx do
      assert {:error, %Error.Output.Parse{field: "tags"}} =
               Adapter.Chat.parse(
                 ctx.signature,
                 {:text, "[[ ## label ## ]]\nbug\n[[ ## confidence ## ]]\n1.0"},
                 []
               )
    end

    test "rejects a repeated output marker", ctx do
      reply =
        "[[ ## label ## ]]\nbug\n[[ ## label ## ]]\nother\n[[ ## confidence ## ]]\n1.0\n[[ ## tags ## ]]\n[]"

      assert {:error, %Error.Output.Parse{field: "label", message: message}} =
               Adapter.Chat.parse(ctx.signature, {:text, reply}, [])

      assert message =~ "more than once"
    end

    test "recognizes markers with irregular spacing", ctx do
      reply =
        "[[ ## label ##]]\nbug\n[[## confidence ## ]]\n0.5\n[[ ##tags##]]\n[]\n[[ ## completed ##]]"

      assert {:ok, %{"label" => "bug", "confidence" => 0.5, "tags" => []}} =
               Adapter.Chat.parse(ctx.signature, {:text, reply}, [])
    end

    test "decodes non-string fields as strict JSON without repair", ctx do
      reply = "[[ ## label ## ]]\nbug\n[[ ## confidence ## ]]\n1.0\n[[ ## tags ## ]]\n['crash',]"

      assert {:error, %Error.Output.Parse{field: "tags"}} =
               Adapter.Chat.parse(ctx.signature, {:text, reply}, [])
    end

    test "keeps string values verbatim after trimming" do
      {:ok, signature} = Signature.new(inputs: [q: Zoi.string()], outputs: [answer: Zoi.string()])

      assert {:ok, %{"answer" => "{\"not\": \"decoded\"}\n  second line"}} =
               Adapter.Chat.parse(
                 signature,
                 {:text, "[[ ## answer ## ]]\n  {\"not\": \"decoded\"}\n  second line\n"},
                 []
               )
    end
  end

  describe "JSON parsing" do
    test "rejects malformed JSON instead of repairing it", ctx do
      assert {:error, %Error.Output.Parse{}} =
               Adapter.JSON.parse(ctx.signature, {:text, @trailing_comma}, mode: :text)
    end

    test "rejects non-object JSON and missing keys", ctx do
      assert {:error, %Error.Output.Parse{}} =
               Adapter.JSON.parse(ctx.signature, {:text, "[1, 2]"}, mode: :text)

      assert {:error, %Error.Output.Parse{field: "tags"}} =
               Adapter.JSON.parse(ctx.signature, {:text, ~s({"label": "bug", "confidence": 1.0})},
                 mode: :text
               )
    end

    test "ignores undeclared keys", ctx do
      assert {:ok, parsed} =
               Adapter.JSON.parse(
                 ctx.signature,
                 {:object,
                  %{"label" => "bug", "confidence" => 1.0, "tags" => [], "reasoning" => "x"}},
                 mode: :structured
               )

      refute Map.has_key?(parsed, "reasoning")
    end
  end

  describe "options" do
    test "Chat accepts no options" do
      assert {:ok, []} = Adapter.Chat.normalize_options([])

      assert {:error, %Error.Invalid.Option{option: :mode}} =
               Adapter.Chat.normalize_options(mode: :text)
    end

    test "JSON requires an explicit mode" do
      assert {:ok, [mode: :structured]} = Adapter.JSON.normalize_options(mode: :structured)
      assert {:error, %Error.Invalid.Option{option: :mode}} = Adapter.JSON.normalize_options([])

      assert {:error, %Error.Invalid.Option{option: :mode}} =
               Adapter.JSON.normalize_options(mode: :auto)

      assert {:error, %Error.Invalid.Option{option: :fallback}} =
               Adapter.JSON.normalize_options(mode: :text, fallback: true)
    end
  end

  defp transcript(context) do
    Enum.map_join(context.messages, "\n", fn message ->
      text = Enum.map_join(message.content, "", & &1.text)
      "==== #{message.role}\n#{text}\n"
    end)
  end
end
