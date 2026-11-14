defmodule Tune.SignatureTest do
  use ExUnit.Case, async: true

  alias Tune.Error
  alias Tune.Signature

  defp signature!(opts) do
    {:ok, signature} = Signature.new(opts)
    signature
  end

  describe "new/1" do
    test "keeps declared order, converts atom names once, and defaults instructions" do
      signature =
        signature!(
          inputs: [context: Zoi.string(), question: Zoi.string()],
          outputs: [answer: Zoi.string(), sources: Zoi.array(Zoi.string())]
        )

      assert Signature.input_names(signature) == ["context", "question"]
      assert Signature.output_names(signature) == ["answer", "sources"]

      assert signature.instructions ==
               "Given the fields `context`, `question`, produce the fields `answer`, `sources`."
    end

    test "rejects atom and string names that collide" do
      assert {:error, %Error.Invalid.Definition{message: message}} =
               Signature.new(
                 inputs: [{:text, Zoi.string()}, {"text", Zoi.string()}],
                 outputs: [a: Zoi.string()]
               )

      assert message =~ "duplicate field names: text"
    end

    test "rejects an input and output with the same name" do
      assert {:error, %Error.Invalid.Definition{}} =
               Signature.new(inputs: [x: Zoi.string()], outputs: [x: Zoi.string()])
    end

    test "rejects names that cannot be XML element or marker names" do
      for name <- ["has space", "1st", "xml_value", "completed", "a-b"] do
        assert {:error, %Error.Invalid.Definition{}} =
                 Signature.new(inputs: [{name, Zoi.string()}], outputs: [out: Zoi.string()]),
               "expected #{inspect(name)} to be rejected"
      end
    end

    test "rejects schemas that are not portable JSON contracts" do
      unsupported = [
        Zoi.any(),
        Zoi.enum([:a, :b]),
        Zoi.atom(),
        Zoi.string() |> Zoi.transform(&String.upcase/1),
        Zoi.string() |> Zoi.default("x"),
        Zoi.string() |> Zoi.optional(),
        Zoi.object(%{name: Zoi.string()}),
        Zoi.array(Zoi.any())
      ]

      for schema <- unsupported do
        assert {:error, %Error.Invalid.Definition{}} =
                 Signature.new(inputs: [in: Zoi.string()], outputs: [out: schema]),
               "expected #{inspect(schema)} to be rejected"
      end
    end

    test "accepts nested JSON objects, arrays, enums, literals, and nullable values" do
      assert {:ok, _signature} =
               Signature.new(
                 inputs: [in: Zoi.string()],
                 outputs: [
                   facts:
                     Zoi.array(
                       Zoi.object(%{
                         "text" => Zoi.string(),
                         "source" => Zoi.integer(),
                         "note" => Zoi.string() |> Zoi.optional()
                       })
                     ),
                   kind: Zoi.enum(["a", "b"]),
                   version: Zoi.literal(1),
                   score: Zoi.nullable(Zoi.float()),
                   tags: Zoi.map(Zoi.string(), Zoi.boolean())
                 ]
               )
    end

    test "rejects unknown options and empty field lists" do
      assert {:error, %Error.Invalid.Option{option: :input}} =
               Signature.new(input: [a: Zoi.string()], outputs: [b: Zoi.string()])

      assert {:error, %Error.Invalid.Definition{}} =
               Signature.new(inputs: [], outputs: [b: Zoi.string()])
    end
  end

  describe "normalize_inputs/2" do
    setup do
      %{
        signature:
          signature!(
            inputs: [question: Zoi.string(), limit: Zoi.integer()],
            outputs: [a: Zoi.string()]
          )
      }
    end

    test "accepts declared atom or string keys and returns string keys", %{signature: signature} do
      assert {:ok, %{"question" => "q", "limit" => 2}} =
               Signature.normalize_inputs(signature, %{:question => "q", "limit" => 2})
    end

    test "rejects keys given as both atom and string", %{signature: signature} do
      assert {:error, %Error.Invalid.Input{message: message}} =
               Signature.normalize_inputs(signature, %{
                 :question => "a",
                 "question" => "b",
                 limit: 1
               })

      assert message =~ "more than once"
    end

    test "rejects unknown keys without creating atoms", %{signature: signature} do
      key = "not_an_existing_atom_#{System.unique_integer([:positive])}"

      assert {:error, %Error.Invalid.Input{}} =
               Signature.normalize_inputs(signature, %{key => 1, question: "q", limit: 1})

      assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    end

    test "reports missing and mistyped values", %{signature: signature} do
      assert {:error, %Error.Invalid.Input{message: message}} =
               Signature.normalize_inputs(signature, %{question: 5})

      assert message =~ "question"
      assert message =~ "limit"
    end
  end
end
