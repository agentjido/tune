defmodule Tune.Artifact.Program do
  @moduledoc false

  alias Tune.CanonicalJSON
  alias Tune.Demo
  alias Tune.Error
  alias Tune.Field
  alias Tune.Parameter
  alias Tune.Predictor
  alias Tune.Signature

  @predictor_keys ["kind", "fingerprint", "instructions", "demos"]
  @value_keys ["kind", "fingerprint", "value"]
  @prose_keys [
    :description,
    :title,
    :examples,
    "description",
    "title",
    "examples",
    :"$schema",
    "$schema"
  ]

  @spec project(Tune.Program.t()) :: {:ok, map()} | {:error, Exception.t()}
  def project(program) do
    with {:ok, parameters} <- Tune.Program.parameters(program) do
      {:ok, Map.new(parameters, fn {name, value} -> {name, entry(value)} end)}
    end
  end

  @spec target_fingerprint(Tune.Program.t()) :: {:ok, String.t()} | {:error, Exception.t()}
  def target_fingerprint(program) do
    with {:ok, parameters} <- Tune.Program.parameters(program) do
      contract =
        Map.new(parameters, fn {name, value} ->
          {name, %{"kind" => kind(value), "fingerprint" => fingerprint(value)}}
        end)

      {:ok, hash(contract)}
    end
  end

  @spec apply(Tune.Program.t(), map()) :: {:ok, Tune.Program.t()} | {:error, Exception.t()}
  def apply(program, entries) when is_map(entries) do
    with :ok <- validate_entries(entries),
         {:ok, parameters} <- Tune.Program.parameters(program),
         :ok <- same_names(parameters, entries),
         {:ok, updates} <- updates(parameters, entries) do
      Tune.Program.replace_parameters(program, updates)
    end
  end

  def apply(_program, other),
    do: invalid("artifact parameters must be an object: #{inspect(other)}")

  @spec validate_entries(map()) :: :ok | {:error, Exception.t()}
  def validate_entries(entries) when is_map(entries) do
    Enum.reduce_while(entries, :ok, fn {name, entry}, :ok ->
      case check_entry(name, entry) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def validate_entries(_entries), do: invalid("artifact parameters must be an object")

  @spec fingerprint(Predictor.t() | Parameter.t()) :: String.t()
  def fingerprint(%Predictor{signature: %Signature{inputs: inputs, outputs: outputs}}) do
    hash(%{"inputs" => field_contract(inputs), "outputs" => field_contract(outputs)})
  end

  def fingerprint(%Parameter{schema: schema}),
    do: hash(%{"schema" => strip(Field.json_schema(schema))})

  defp field_contract(fields),
    do: Enum.map(fields, &[&1.name, strip(Field.json_schema(&1.schema))])

  defp hash(contract) do
    contract
    |> CanonicalJSON.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp strip(map) when is_map(map) do
    map
    |> Map.drop(@prose_keys)
    |> Map.new(fn {key, value} -> {to_string(key), strip_keyword(to_string(key), value)} end)
  end

  defp strip(value), do: value

  defp strip_keyword(key, fields) when key in ["properties", "patternProperties"],
    do: Map.new(fields, fn {name, schema} -> {to_string(name), strip(schema)} end)

  defp strip_keyword(key, schemas) when key in ["anyOf", "oneOf", "allOf", "prefixItems"],
    do: Enum.map(schemas, &strip/1)

  defp strip_keyword(key, schema) when key in ["items", "additionalProperties", "propertyNames"],
    do: strip(schema)

  defp strip_keyword(_key, value), do: canonical_value(value)

  defp canonical_value(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), canonical_value(value)} end)

  defp canonical_value(list) when is_list(list), do: Enum.map(list, &canonical_value/1)

  defp canonical_value(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp canonical_value(value), do: value

  defp entry(%Predictor{} = predictor) do
    %{
      "kind" => "predictor",
      "fingerprint" => fingerprint(predictor),
      "instructions" => predictor.signature.instructions,
      "demos" => Enum.map(predictor.demos, &%{"inputs" => &1.inputs, "outputs" => &1.outputs})
    }
  end

  defp entry(%Parameter{} = parameter) do
    %{"kind" => "value", "fingerprint" => fingerprint(parameter), "value" => parameter.value}
  end

  defp kind(%Predictor{}), do: "predictor"
  defp kind(%Parameter{}), do: "value"

  defp check_entry(name, %{"kind" => "predictor"} = entry) do
    cond do
      Enum.sort(Map.keys(entry)) != Enum.sort(@predictor_keys) ->
        invalid("entry #{inspect(name)} has unknown or missing fields")

      not is_binary(entry["fingerprint"]) ->
        invalid("entry #{inspect(name)} needs a fingerprint")

      not is_binary(entry["instructions"]) ->
        invalid("entry #{inspect(name)} needs instructions")

      not is_list(entry["demos"]) ->
        invalid("entry #{inspect(name)} needs a demos list")

      not Enum.all?(entry["demos"], &demo_shape?/1) ->
        invalid("entry #{inspect(name)} has invalid demos")

      true ->
        :ok
    end
  end

  defp check_entry(name, %{"kind" => "value"} = entry) do
    cond do
      Enum.sort(Map.keys(entry)) != Enum.sort(@value_keys) ->
        invalid("entry #{inspect(name)} has unknown or missing fields")

      not is_binary(entry["fingerprint"]) ->
        invalid("entry #{inspect(name)} needs a fingerprint")

      true ->
        :ok
    end
  end

  defp check_entry(name, _entry), do: invalid("entry #{inspect(name)} has an unknown kind")

  defp demo_shape?(%{"inputs" => inputs, "outputs" => outputs} = demo)
       when is_map(inputs) and is_map(outputs) and map_size(demo) == 2,
       do: true

  defp demo_shape?(_demo), do: false

  defp same_names(parameters, entries) do
    expected = parameters |> Map.keys() |> Enum.sort()
    given = entries |> Map.keys() |> Enum.sort()

    if expected == given,
      do: :ok,
      else:
        invalid(
          "artifact entries #{inspect(given)} do not match program parameters #{inspect(expected)}"
        )
  end

  defp updates(parameters, entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {name, entry}, {:ok, acc} ->
      case update(name, Map.fetch!(parameters, name), entry) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, name, value)}}
        error -> {:halt, error}
      end
    end)
  end

  defp update(name, %Predictor{} = predictor, %{"kind" => "predictor"} = entry) do
    with :ok <- same_fingerprint(name, predictor, entry),
         {:ok, predictor} <- Predictor.put_instructions(predictor, entry["instructions"]),
         {:ok, demos} <- Demo.new_list(predictor.signature, entry["demos"]) do
      {:ok, %{predictor | demos: demos}}
    else
      {:error, %Error.Invalid.Definition{} = error} ->
        invalid("entry #{inspect(name)}: #{Exception.message(error)}")

      error ->
        error
    end
  end

  defp update(name, %Parameter{} = parameter, %{"kind" => "value"} = entry) do
    with :ok <- same_fingerprint(name, parameter, entry),
         {:ok, parameter} <- Parameter.put_value(parameter, entry["value"]) do
      {:ok, parameter}
    else
      {:error, %Error.Invalid.Definition{} = error} ->
        invalid("entry #{inspect(name)}: #{Exception.message(error)}")
    end
  end

  defp update(name, _parameter, _entry),
    do: invalid("entry #{inspect(name)} has a different kind than the program")

  defp same_fingerprint(name, parameter, entry) do
    if fingerprint(parameter) == entry["fingerprint"],
      do: :ok,
      else: invalid("entry #{inspect(name)} was learned for a different field or schema contract")
  end

  defp invalid(message), do: {:error, Error.Invalid.Definition.exception(message: message)}
end
