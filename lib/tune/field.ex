defmodule Tune.Field do
  @moduledoc """
  One named, typed signature field.

  Names are trusted identifiers stored as strings. They must be valid XML
  element names made of ASCII letters, digits, and underscores, must not start
  with `xml`, and must not be `completed`, which the Chat format reserves.

  Schemas are Zoi schemas restricted to JSON-representable values: strings,
  integers, floats, numbers, booleans, null, string enums, scalar literals,
  arrays, string-keyed objects, string-keyed records, and unions of those,
  including nullable fields. Transforms, defaults, and optional top-level fields
  are rejected so a reply cannot pass validation by omission or rewriting.
  """

  alias Tune.Error

  @name_pattern ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/
  @reserved_names ["completed"]

  @enforce_keys [:name, :schema]
  defstruct [:name, :schema, :description]

  @type t :: %__MODULE__{name: String.t(), schema: Zoi.schema(), description: String.t() | nil}

  @type spec ::
          t()
          | {atom() | String.t(), Zoi.schema()}
          | {atom() | String.t(), Zoi.schema(), keyword()}

  @doc "Normalizes one field specification."
  @spec new(spec()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%__MODULE__{name: name, schema: schema, description: description}),
    do: build(name, schema, description: description)

  def new({name, schema}), do: build(name, schema, [])
  def new({name, schema, opts}) when is_list(opts), do: build(name, schema, opts)
  def new(other), do: definition_error("invalid field specification: #{inspect(other)}")

  defp build(name, schema, opts) do
    with {:ok, name} <- normalize_name(name),
         :ok <- check_schema(schema, name, true),
         {:ok, description} <- description(schema, opts) do
      {:ok, %__MODULE__{name: name, schema: schema, description: description}}
    end
  end

  defp normalize_name(name) when is_atom(name) and not is_nil(name) and not is_boolean(name),
    do: normalize_name(Atom.to_string(name))

  defp normalize_name(name) when is_binary(name) do
    cond do
      not Regex.match?(@name_pattern, name) ->
        definition_error("field name #{inspect(name)} must be an XML-safe identifier")

      String.downcase(name) |> String.starts_with?("xml") ->
        definition_error("field name #{inspect(name)} must not start with \"xml\"")

      name in @reserved_names ->
        definition_error("field name #{inspect(name)} is reserved")

      true ->
        {:ok, name}
    end
  end

  defp normalize_name(name), do: definition_error("invalid field name: #{inspect(name)}")

  defp description(schema, opts) do
    case Keyword.get(opts, :description) || schema.meta.description do
      nil -> {:ok, nil}
      text when is_binary(text) -> {:ok, text}
      other -> definition_error("field description must be a string, got: #{inspect(other)}")
    end
  end

  @doc """
  Returns `true` when the schema's reply text is used verbatim by text formats.

  String, string enum, and string literal schemas, optionally nullable, read the
  raw field text. Every other schema is decoded as JSON.
  """
  @spec text_valued?(Zoi.schema()) :: boolean()
  def text_valued?(%Zoi.Types.String{}), do: true
  def text_valued?(%Zoi.Types.Enum{enum_type: :binary}), do: true
  def text_valued?(%Zoi.Types.Literal{value: value}) when is_binary(value), do: true

  def text_valued?(%Zoi.Types.Union{schemas: schemas}) do
    case Enum.reject(schemas, &match?(%Zoi.Types.Null{}, &1)) do
      [] -> false
      rest -> Enum.all?(rest, &text_valued?/1)
    end
  end

  def text_valued?(_schema), do: false

  @doc "Returns `true` when the schema accepts `nil`."
  @spec nullable?(Zoi.schema()) :: boolean()
  def nullable?(%Zoi.Types.Null{}), do: true
  def nullable?(%Zoi.Types.Union{schemas: schemas}), do: Enum.any?(schemas, &nullable?/1)
  def nullable?(_schema), do: false

  @doc "Returns the field's JSON Schema without the top-level `$schema` keyword."
  @spec json_schema(t() | Zoi.schema()) :: map()
  def json_schema(%__MODULE__{schema: schema}), do: json_schema(schema)
  def json_schema(schema), do: schema |> Zoi.to_json_schema() |> Map.delete(:"$schema")

  @doc """
  Checks that a schema is a supported JSON-compatible contract.

  Used for parameter schemas, which follow the same rules as top-level fields.
  """
  @spec check_schema(term(), String.t()) :: :ok | {:error, Exception.t()}
  def check_schema(schema, path), do: check_schema(schema, path, true)

  defp check_schema(schema, path, top_level?) when is_struct(schema) do
    with :ok <- check_meta(schema, path, top_level?) do
      check_type(schema, path)
    end
  end

  defp check_schema(schema, path, _top_level?),
    do: definition_error("#{path}: expected a Zoi schema, got: #{inspect(schema)}")

  defp check_meta(%{meta: %Zoi.Types.Meta{} = meta}, path, top_level?) do
    cond do
      Enum.any?(meta.effects, &match?({:transform, _}, &1)) ->
        definition_error("#{path}: transforms are not supported")

      top_level? and meta.default != nil ->
        definition_error("#{path}: declared fields must not have defaults")

      top_level? and meta.required == false ->
        definition_error("#{path}: declared fields must be required; use a nullable schema")

      true ->
        :ok
    end
  end

  defp check_meta(schema, path, _top_level?),
    do: definition_error("#{path}: unsupported schema #{inspect(schema)}")

  defp check_type(%type{}, _path)
       when type in [
              Zoi.Types.String,
              Zoi.Types.Integer,
              Zoi.Types.Float,
              Zoi.Types.Number,
              Zoi.Types.Boolean,
              Zoi.Types.Null
            ],
       do: :ok

  defp check_type(%Zoi.Types.Enum{enum_type: :binary}, _path), do: :ok

  defp check_type(%Zoi.Types.Enum{}, path),
    do: definition_error("#{path}: enums must have string values")

  defp check_type(%Zoi.Types.Literal{value: value}, _path)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: :ok

  defp check_type(%Zoi.Types.Array{prefix_items: [], inner: inner}, path),
    do: check_schema(inner, "#{path}[]", false)

  defp check_type(%Zoi.Types.Map{fields: fields}, path) when is_list(fields) do
    Enum.reduce_while(fields, :ok, fn {key, schema}, :ok ->
      result =
        if is_binary(key),
          do: check_schema(schema, "#{path}.#{key}", false),
          else:
            definition_error("#{path}: nested object keys must be strings, got: #{inspect(key)}")

      if result == :ok, do: {:cont, :ok}, else: {:halt, result}
    end)
  end

  defp check_type(%Zoi.Types.Map{key_type: %Zoi.Types.String{}, value_type: value_type}, path),
    do: check_schema(value_type, "#{path}{}", false)

  defp check_type(%Zoi.Types.Union{schemas: schemas}, path) do
    Enum.reduce_while(schemas, :ok, fn schema, :ok ->
      case check_schema(schema, path, false) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp check_type(schema, path),
    do: definition_error("#{path}: unsupported schema type #{inspect(schema.__struct__)}")

  defp definition_error(message),
    do: {:error, Error.Invalid.Definition.exception(message: message)}
end
