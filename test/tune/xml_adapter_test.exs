defmodule Tune.XMLAdapterTest do
  use ExUnit.Case, async: true

  alias Tune
  alias Tune.Adapter
  alias Tune.Demo
  alias Tune.Error
  alias Tune.Predictor
  alias Tune.Signature
  alias Tune.TestSupport.Transport

  @fixtures Path.expand("../fixtures/prompts", __DIR__)

  @fact Zoi.object(%{
          "text" => Zoi.string(),
          "source" => Zoi.string(),
          "score" => Zoi.nullable(Zoi.float())
        })

  setup do
    {:ok, signature} =
      Signature.new(
        instructions: "Answer from the facts.",
        inputs: [question: Zoi.string(), facts: Zoi.array(@fact)],
        outputs: [
          answer: Zoi.string(),
          sources: Zoi.array(Zoi.string()),
          confident: Zoi.boolean()
        ]
      )

    {:ok, demo} =
      Demo.new(signature, %{
        inputs: %{
          question: "Capital?",
          facts: [%{"text" => "Paris is the capital.", "source" => "p2", "score" => nil}]
        },
        outputs: %{answer: "Paris", sources: ["p2"], confident: true}
      })

    {:ok, opts} = Adapter.XML.normalize_options([])
    %{signature: signature, demo: demo, opts: opts}
  end

  test "renders schema-directed elements, nested objects, and item arrays", ctx do
    inputs = %{
      "question" => "Where?",
      "facts" => [%{"text" => "It is in Paris.", "source" => "p1", "score" => 0.5}]
    }

    assert {:ok, %{context: context, output: output}} =
             Adapter.XML.render(ctx.signature, [ctx.demo], inputs, ctx.opts)

    assert output == ReqLLM.Output.text()
    assert transcript(context) == File.read!(Path.join(@fixtures, "xml_grounded.txt"))
  end

  test "a rendered demonstration parses back to the same values", ctx do
    {:ok, %{context: context}} =
      Adapter.XML.render(ctx.signature, [ctx.demo], %{"question" => "q", "facts" => []}, ctx.opts)

    assistant = Enum.find(context.messages, &(&1.role == :assistant))
    text = Enum.map_join(assistant.content, "", & &1.text)

    assert {:ok, parsed} = Adapter.XML.parse(ctx.signature, {:text, text}, ctx.opts)
    assert {:ok, outputs} = Signature.validate_outputs(ctx.signature, parsed)
    assert outputs == ctx.demo.outputs
  end

  test "nested values, nulls, and empty arrays parse by schema" do
    {:ok, signature} =
      Signature.new(
        inputs: [q: Zoi.string()],
        outputs: [facts: Zoi.array(@fact), tags: Zoi.array(Zoi.string())]
      )

    reply = """
    <facts>
    <item>
    <source>p1</source>
    <text>A & B < C</text>
    <score>null</score>
    </item>
    <item><text>Second</text><source>p2</source><score>0.25</score></item>
    </facts>
    <tags>
    </tags>
    """

    assert {:ok, parsed} = Adapter.XML.parse(signature, {:text, reply}, [])

    assert {:ok, %{"facts" => [first, second], "tags" => []}} =
             Signature.validate_outputs(signature, parsed)

    assert first == %{"text" => "A & B < C", "source" => "p1", "score" => nil}
    assert second == %{"text" => "Second", "source" => "p2", "score" => 0.25}
  end

  test "raw code with angle brackets stays verbatim", ctx do
    code = "if a < b and b > c:\n    print(\"<tag>\")"

    reply =
      "<answer>\n#{code}\n</answer>\n<sources>\n<item>p1</item>\n</sources>\n<confident>\nfalse\n</confident>"

    assert {:ok, %{"answer" => ^code, "sources" => ["p1"], "confident" => false}} =
             Adapter.XML.parse(ctx.signature, {:text, reply}, ctx.opts)
  end

  test "entity and DTD text is never expanded", ctx do
    dtd = ~s(<!DOCTYPE x [<!ENTITY e SYSTEM "file:///etc/passwd">]>&e; &amp;)
    reply = "<answer>#{dtd}</answer><sources></sources><confident>true</confident>"

    assert {:ok, %{"answer" => ^dtd}} = Adapter.XML.parse(ctx.signature, {:text, reply}, ctx.opts)
  end

  test "rejects missing, duplicate, unclosed, and mistyped fields", ctx do
    cases = [
      {"<answer>x</answer><sources></sources>", "confident"},
      {"<answer>x</answer><answer>y</answer><sources></sources><confident>true</confident>",
       "answer"},
      {"<answer>x</answer><sources><item>p1</item><confident>true</confident>", "sources"},
      {"<answer>x</answer><sources></sources><confident>yes</confident>", "confident"}
    ]

    for {reply, field} <- cases do
      assert {:error, %Error.Output.Parse{field: ^field}} =
               Adapter.XML.parse(ctx.signature, {:text, reply}, ctx.opts),
             "expected #{inspect(reply)} to fail on #{field}"
    end
  end

  test "rejects string values that contain their own closing tag before rendering", ctx do
    assert {:error, %Error.Invalid.Input{message: message}} =
             Adapter.XML.render(
               ctx.signature,
               [],
               %{"question" => "what is </question>?", "facts" => []},
               ctx.opts
             )

    assert message =~ "question"

    assert {:error, %Error.Invalid.Input{message: nested}} =
             Adapter.XML.render(
               ctx.signature,
               [],
               %{
                 "question" => "q",
                 "facts" => [%{"text" => "a </text> b", "source" => "p", "score" => nil}]
               },
               ctx.opts
             )

    assert nested =~ "facts.item.text"
  end

  test "bounds reply size and nesting depth" do
    {:ok, signature} =
      Signature.new(
        inputs: [q: Zoi.string()],
        outputs: [deep: Zoi.array(Zoi.array(Zoi.string()))]
      )

    {:ok, small} = Adapter.XML.normalize_options(max_reply_bytes: 10)
    {:ok, shallow} = Adapter.XML.normalize_options(max_depth: 1)

    reply = "<deep><item><item>x</item></item></deep>"
    assert {:error, %Error.Output.Parse{}} = Adapter.XML.parse(signature, {:text, reply}, small)
    assert {:error, %Error.Output.Parse{}} = Adapter.XML.parse(signature, {:text, reply}, shallow)
    assert {:ok, %{"deep" => [["x"]]}} = Adapter.XML.parse(signature, {:text, reply}, [])

    assert {:error, %Error.Invalid.Option{option: :other}} =
             Adapter.XML.normalize_options(other: 1)
  end

  test "a classifier gives the same typed output as Chat and JSON, with one request" do
    {:ok, predictor} =
      Predictor.new(
        signature: [
          inputs: [ticket: Zoi.string()],
          outputs: [label: Zoi.enum(["billing", "bug"]), confidence: Zoi.float()]
        ]
      )

    stub =
      Transport.script([
        {:text, "<label>\nbilling\n</label>\n\n<confidence>\n0.8\n</confidence>"},
        {:text, "unused"}
      ])

    config = [
      model: Transport.model(),
      adapter: Adapter.XML,
      request_options: Transport.request_options(stub)
    ]

    assert {:ok, result} = Tune.run(predictor, %{ticket: "charged twice"}, model: config)
    assert result.output == %{"label" => "billing", "confidence" => 0.8}
    assert [_one] = Transport.requests(stub)

    bad = Transport.script([{:text, "<label>billing</label>"}, {:text, "unused"}])

    config = [
      model: Transport.model(),
      adapter: Adapter.XML,
      request_options: Transport.request_options(bad)
    ]

    assert {:error, %Error.Execution.Failed{cause: %Error.Output.Parse{field: "confidence"}}} =
             Tune.run(predictor, %{ticket: "x"}, model: config)

    assert [_one] = Transport.requests(bad)
  end

  defp transcript(context) do
    Enum.map_join(context.messages, "\n", fn message ->
      "==== #{message.role}\n#{Enum.map_join(message.content, "", & &1.text)}\n"
    end)
  end
end
