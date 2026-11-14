defmodule Tune.Signature do
  @moduledoc """
  Ordered, typed input and output fields plus task instructions.

      {:ok, signature} =
        Tune.Signature.new(
          instructions: "Classify the support ticket.",
          inputs: [ticket: Zoi.string(description: "Customer message")],
          outputs: [label: Zoi.enum(["billing", "bug", "other"])]
        )

  Field names are normalized to strings once. Field order is preserved in
  every prompt format. Input and output values are string-keyed maps.
  Instructions are the only tunable part of a signature.
  """

  alias Tune.Error
  alias Tune.Field

  @enforce_keys [:instructions, :inputs, :outputs, :input_schema, :output_schema]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          instructions: String.t(),
          inputs: [Field.t()],
          outputs: [Field.t()],
          input_schema: Zoi.schema(),
          output_schema: Zoi.schema()
        }

  @doc """
  Builds a signature.

  Options:

    * `:inputs` - nonempty list of field specifications
    * `:outputs` - nonempty list of field specifications
    * `:instructions` - task instructions; defaults to a sentence naming the fields
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, Exception.t()}
  def new(opts) when is_map(opts), do: opts |> Map.to_list() |> new()

  def new(opts) when is_list(opts) do
    with :ok <- check_keys(opts),
         {:ok, inputs} <- fields(opts, :inputs),
         {:ok, outputs} <- fields(opts, :outputs),
         :ok <- check_unique(inputs ++ outputs),
         {:ok, instructions} <- instructions(opts, inputs, outputs) do
      {:ok,
       %__MODULE__{
         instructions: instructions,
         inputs: inputs,
         outputs: outputs,
         input_schema: object_schema(inputs),
         output_schema: object_schema(outputs)
       }}
    end
  end

  def new(other),
    do: definition_error("signature options must be a keyword list, got: #{inspect(other)}")

  @doc "Returns a signature with replaced instructions."
  @spec put_instructions(t(), String.t()) :: {:ok, t()} | {:error, Exception.t()}
  def put_instructions(%__MODULE__{} = signature, instructions)
      when is_binary(instructions) do
    if String.trim(instructions) == "",
      do: definition_error("instructions must not be empty"),
      else: {:ok, %{signature | instructions: instructions}}
  end

  def put_instructions(%__MODULE__{}, other),
    do: definition_error("instructions must be a string, got: #{inspect(other)}")

  @doc "Returns input field names in declared order."
  @spec input_names(t()) :: [String.t()]
  def input_names(%__MODULE__{inputs: inputs}), do: Enum.map(inputs, & &1.name)

  @doc "Returns output field names in declared order."
  @spec output_names(t()) :: [String.t()]
  def output_names(%__MODULE__{outputs: outputs}), do: Enum.map(outputs, & &1.name)

  @doc """
  Normalizes and validates input values.

  Top-level keys may be declared strings or the matching trusted atoms. Unknown
  keys, missing keys, and atom/string duplicates are errors. No atoms are created.
  """
  @spec normalize_inputs(t(), map()) :: {:ok, map()} | {:error, Exception.t()}
  def normalize_inputs(%__MODULE__{} = signature, values) when is_map(values) do
    with {:ok, values} <- normalize_keys(values, input_names(signature)) do
      case Zoi.parse(signature.input_schema, values) do
        {:ok, parsed} ->
          {:ok, parsed}

        {:error, errors} ->
          {:error,
           Error.Invalid.Input.exception(
             message: format_errors("invalid inputs", errors),
             errors: errors
           )}
      end
    end
  end

  def normalize_inputs(%__MODULE__{}, other),
    do:
      {:error,
       Error.Invalid.Input.exception(
         message: "inputs must be a map, got: #{inspect(other)}",
         errors: []
       )}

  @doc "Validates a string-keyed output map against the declared output schema."
  @spec validate_outputs(t(), map()) :: {:ok, map()} | {:error, [Zoi.Error.t()]}
  def validate_outputs(%__MODULE__{output_schema: schema}, values), do: Zoi.parse(schema, values)

  @doc false
  @spec format_errors(String.t(), [Zoi.Error.t()]) :: String.t()
  def format_errors(prefix, errors) do
    details =
      Enum.map_join(errors, "; ", fn %Zoi.Error{path: path, message: message} ->
        if path == [], do: message, else: "#{Enum.join(path, ".")}: #{message}"
      end)

    "#{prefix}: #{details}"
  end

  defp check_keys(opts) do
    case Keyword.keys(opts) -- [:inputs, :outputs, :instructions] do
      [] ->
        :ok

      [key | _] ->
        {:error, Error.Invalid.Option.exception(option: key, message: "unknown signature option")}
    end
  end

  defp fields(opts, key) do
    case Keyword.get(opts, key) do
      [_ | _] = specs ->
        Enum.reduce_while(specs, {:ok, []}, fn spec, {:ok, acc} ->
          case Field.new(spec) do
            {:ok, field} -> {:cont, {:ok, [field | acc]}}
            error -> {:halt, error}
          end
        end)
        |> then(fn
          {:ok, fields} -> {:ok, Enum.reverse(fields)}
          error -> error
        end)

      _ ->
        definition_error("#{key} must be a nonempty list of fields")
    end
  end

  defp check_unique(fields) do
    duplicates =
      fields
      |> Enum.frequencies_by(& &1.name)
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    case duplicates do
      [] -> :ok
      names -> definition_error("duplicate field names: #{Enum.join(names, ", ")}")
    end
  end

  defp instructions(opts, inputs, outputs) do
    case Keyword.get(opts, :instructions) do
      nil ->
        {:ok, default_instructions(inputs, outputs)}

      text when is_binary(text) ->
        if String.trim(text) == "",
          do: {:ok, default_instructions(inputs, outputs)},
          else: {:ok, text}

      other ->
        definition_error("instructions must be a string, got: #{inspect(other)}")
    end
  end

  defp default_instructions(inputs, outputs) do
    "Given the fields #{quote_names(inputs)}, produce the fields #{quote_names(outputs)}."
  end

  defp quote_names(fields), do: Enum.map_join(fields, ", ", &"`#{&1.name}`")

  defp object_schema(fields) do
    fields
    |> Map.new(&{&1.name, &1.schema})
    |> Zoi.object(unrecognized_keys: :error)
  end

  defp normalize_keys(values, names) do
    Enum.reduce_while(values, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, name} <- key_name(key, names),
           false <- Map.has_key?(acc, name) do
        {:cont, {:ok, Map.put(acc, name, value)}}
      else
        true -> {:halt, input_error("input #{inspect(key)} is given more than once")}
        error -> {:halt, error}
      end
    end)
  end

  defp key_name(key, names) when is_binary(key) do
    if key in names, do: {:ok, key}, else: input_error("unknown input #{inspect(key)}")
  end

  defp key_name(key, names) when is_atom(key) do
    name = Atom.to_string(key)
    if name in names, do: {:ok, name}, else: input_error("unknown input #{inspect(key)}")
  end

  defp key_name(key, _names), do: input_error("invalid input key #{inspect(key)}")

  defp input_error(message),
    do: {:error, Error.Invalid.Input.exception(message: message, errors: [])}

  defp definition_error(message),
    do: {:error, Error.Invalid.Definition.exception(message: message)}
end
