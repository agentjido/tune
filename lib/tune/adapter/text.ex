defmodule Tune.Adapter.Text do
  @moduledoc false

  alias Tune.Error
  alias Tune.Field
  alias Tune.Signature

  @spec field_descriptions(Signature.t()) :: String.t()
  def field_descriptions(%Signature{inputs: inputs, outputs: outputs}) do
    Enum.join(
      [
        "Your input fields are:",
        numbered(inputs),
        "Your output fields are:",
        numbered(outputs)
      ],
      "\n"
    )
  end

  @spec objective(Signature.t()) :: String.t()
  def objective(%Signature{instructions: instructions}) do
    indented =
      instructions
      |> String.split("\n")
      |> Enum.map_join("\n", &("        " <> &1))

    "In adhering to this structure, your objective is: \n" <> indented
  end

  @spec header(String.t()) :: String.t()
  def header(name), do: "[[ ## #{name} ## ]]"

  @spec marked_fields([Field.t()], map()) :: String.t()
  def marked_fields(fields, values) do
    Enum.map_join(fields, "\n\n", fn field ->
      header(field.name) <> "\n" <> format_value(Map.fetch!(values, field.name), field.schema)
    end)
  end

  @spec format_value(term(), Zoi.schema()) :: String.t()
  def format_value(value, _schema) when is_binary(value), do: value
  def format_value(value, _schema), do: Jason.encode!(value)

  @spec type_label(Zoi.schema()) :: String.t()
  def type_label(%Zoi.Types.String{}), do: "string"
  def type_label(%Zoi.Types.Integer{}), do: "integer"
  def type_label(%Zoi.Types.Float{}), do: "number"
  def type_label(%Zoi.Types.Number{}), do: "number"
  def type_label(%Zoi.Types.Boolean{}), do: "boolean"
  def type_label(%Zoi.Types.Null{}), do: "null"
  def type_label(%Zoi.Types.Enum{}), do: "enum"
  def type_label(%Zoi.Types.Literal{value: value}), do: "literal #{Jason.encode!(value)}"
  def type_label(%Zoi.Types.Array{inner: inner}), do: "array of #{type_label(inner)}"
  def type_label(%Zoi.Types.Map{}), do: "object"

  def type_label(%Zoi.Types.Union{schemas: schemas}),
    do: Enum.map_join(schemas, " or ", &type_label/1)

  @spec value_requirement(Zoi.schema()) :: String.t() | nil
  def value_requirement(%Zoi.Types.String{}), do: nil

  def value_requirement(%Zoi.Types.Enum{values: values}) do
    "must exactly match (no extra characters) one of: " <>
      Enum.map_join(values, "; ", &elem(&1, 1))
  end

  def value_requirement(schema) do
    if Field.text_valued?(schema),
      do: nil,
      else: "must adhere to the JSON schema: " <> Jason.encode!(Field.json_schema(schema))
  end

  @spec placeholder(Field.t()) :: String.t()
  def placeholder(%Field{name: name, schema: schema}) do
    case value_requirement(schema) do
      nil -> "{#{name}}"
      requirement -> "{#{name}}        # note: the value you produce #{requirement}"
    end
  end

  @spec field_order_hint([Field.t()], (String.t() -> String.t()), String.t()) :: String.t()
  def field_order_hint([first | rest], render_name, lead) do
    tail =
      Enum.map(rest, fn field ->
        "then #{render_name.(field.name)}#{format_hint(field.schema)}"
      end)

    Enum.join(
      [lead <> "#{render_name.(first.name)}#{format_hint(first.schema)}" | tail],
      ", "
    )
  end

  defp format_hint(schema) do
    if Field.text_valued?(schema),
      do: "",
      else: " (must be formatted as valid JSON: #{type_label(schema)})"
  end

  @spec decode_field(Field.t(), String.t()) :: {:ok, term()} | {:error, Exception.t()}
  def decode_field(%Field{schema: schema, name: name}, text) do
    cond do
      Field.text_valued?(schema) and Field.nullable?(schema) and text == "null" ->
        {:ok, nil}

      Field.text_valued?(schema) ->
        {:ok, text}

      true ->
        case Jason.decode(text) do
          {:ok, value} ->
            {:ok, value}

          {:error, _} ->
            {:error,
             Error.Output.Parse.exception(
               message: "field #{inspect(name)} is not valid JSON",
               field: name,
               reply: text
             )}
        end
    end
  end

  defp numbered(fields) do
    fields
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {field, index} ->
      base = "#{index}. `#{field.name}` (#{type_label(field.schema)})"
      if field.description, do: base <> ": " <> field.description, else: base
    end)
  end
end
