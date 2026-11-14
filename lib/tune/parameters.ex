defmodule Tune.Parameters do
  @moduledoc """
  Versioned exchange of learned parameters and run provenance.

  An artifact is plain JSON data. Version 1 has named entries of kind
  `"predictor"` (instructions and demonstrations) or `"value"` (a JSON value),
  each with a fingerprint of the code-owned contract it was learned for:

    * predictor fingerprint: ordered input and output field names and JSON
      schemas
    * value fingerprint: the value's JSON schema

  Fingerprints exclude instructions, values, and schema prose (`description`,
  `title`, `examples`), use canonical JSON with sorted keys, and use SHA-256.
  Annotation removal visits schema positions only. Object property names and
  literal values remain part of the contract, even when they use these names.

  Loading never creates atoms, loads modules, or evaluates code. The
  application supplies the program; `apply/2` checks that the artifact names
  exactly the program's declared parameters with matching kinds and
  fingerprints, validates every value, and then applies all of them at once.
  A failed load changes nothing.

  Provenance is descriptive and allowlisted. It never contains request
  options, credentials, functions, processes, or responses, and it never
  selects models or overrides runtime configuration. Learned demonstrations
  and lessons can contain application text; there is no content-based secret
  removal. Callers own file access.

  Artifacts use the `tune.parameters` format identifier.
  """

  alias Tune
  alias Tune.Demo
  alias Tune.Error
  alias Tune.Example
  alias Tune.Field
  alias Tune.ModelConfig
  alias Tune.Parameter
  alias Tune.Predictor
  alias Tune.Result
  alias Tune.Signature

  @format "tune.parameters"
  @version 1
  @top_keys ["format", "version", "entries", "provenance"]
  @predictor_keys ["kind", "fingerprint", "instructions", "demos"]
  @value_keys ["kind", "fingerprint", "value"]
  @provenance_keys [
    "source",
    "models",
    "optimizer",
    "settings",
    "seed",
    "datasets",
    "best",
    "complete",
    "stop_reason",
    "calls",
    "usage"
  ]
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

  @type artifact :: map()

  @doc """
  Extracts a program's parameters into an artifact map.

  Options:

    * `:provenance` - a map built by `provenance/1`
  """
  @spec dump(Tune.Program.t(), keyword()) :: {:ok, artifact()} | {:error, Exception.t()}
  def dump(program, opts \\ []) do
    with {:ok, parameters} <- Tune.Program.parameters(program),
         {:ok, provenance} <- check_provenance(Keyword.get(opts, :provenance)) do
      entries = Map.new(parameters, fn {name, value} -> {name, entry(value)} end)

      {:ok,
       %{
         "format" => @format,
         "version" => @version,
         "entries" => entries,
         "provenance" => provenance
       }}
    end
  end

  @doc """
  Builds allowlisted provenance.

  Options: `:source` (string), `:report` (an optimizer report), and `:models`
  (keyword or map of role to `ModelConfig`).
  """
  @spec provenance(keyword()) :: map()
  def provenance(opts) do
    report = Keyword.get(opts, :report)

    base = %{
      "source" => Keyword.get(opts, :source),
      "models" =>
        opts
        |> Keyword.get(:models, [])
        |> Map.new(fn {role, %ModelConfig{} = config} ->
          {to_string(role), ModelConfig.describe(config)}
        end)
    }

    if report, do: Map.merge(base, report_provenance(report)), else: base
  end

  @doc "Encodes an artifact as canonical JSON."
  @spec encode(artifact()) :: {:ok, binary()} | {:error, Exception.t()}
  def encode(%{"format" => @format} = artifact), do: {:ok, Example.canonical_json(artifact)}

  def encode(other), do: invalid("not a parameter artifact: #{inspect(other)}")

  @doc """
  Decodes and structurally validates an artifact.

  Options: `:max_bytes` (default 5 000 000) and `:max_entries` (default 1 000).
  """
  @spec decode(binary(), keyword()) :: {:ok, artifact()} | {:error, Exception.t()}
  def decode(binary, opts \\ []) when is_binary(binary) do
    max_bytes = Keyword.get(opts, :max_bytes, 5_000_000)
    max_entries = Keyword.get(opts, :max_entries, 1_000)

    with :ok <- check(byte_size(binary) <= max_bytes, "the artifact exceeds #{max_bytes} bytes"),
         {:ok, data} <- json(binary),
         :ok <- check_top(data),
         :ok <-
           check(
             map_size(data["entries"]) <= max_entries,
             "the artifact has more than #{max_entries} entries"
           ),
         :ok <- check_entries(data["entries"]),
         {:ok, _} <- check_provenance(data["provenance"]) do
      {:ok, Map.put(data, "format", @format)}
    end
  end

  @doc """
  Applies an artifact to application-supplied program code.

  Returns the updated program, or an error and no change.
  """
  @spec apply(Tune.Program.t(), artifact()) :: {:ok, Tune.Program.t()} | {:error, Exception.t()}
  def apply(program, %{"entries" => entries} = artifact) when is_map(entries) do
    with :ok <- check_top(artifact),
         :ok <- check_entries(entries),
         {:ok, parameters} <- Tune.Program.parameters(program),
         :ok <- same_names(parameters, entries),
         {:ok, updates} <- updates(parameters, entries) do
      Tune.Program.replace_parameters(program, updates)
    end
  end

  def apply(_program, other), do: invalid("not a parameter artifact: #{inspect(other)}")

  @doc "Returns the fingerprint of a predictor's or value's code-owned contract."
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
    |> Example.canonical_json()
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

  defp report_provenance(%Result{} = result) do
    metadata = result.metadata
    notes = Map.get(metadata, :notes, %{})
    datasets = Map.get(metadata, :datasets, %{})
    best = result.best
    evaluation = best && best.evaluation
    summary = evaluation && Tune.Evaluation.summary(evaluation, :objective)

    %{
      "optimizer" => inspect(metadata[:strategy]),
      "settings" => Map.get(notes, :settings, %{}),
      "seed" => metadata[:seed],
      "datasets" => Map.new(datasets, fn {key, value} -> {to_string(key), value} end),
      "best" =>
        best &&
          %{
            "id" => best.id,
            "selected_score" => evaluation.selected_score,
            "mean" => summary && summary.mean,
            "coverage" => summary && summary.coverage,
            "eligible" => evaluation.eligible?
          },
      "complete" => result.complete?,
      "stop_reason" => to_string(result.stop_reason),
      "calls" => Map.new(result.calls, fn {role, count} -> {to_string(role), count} end),
      "usage" => Map.new(result.usage, fn {key, value} -> {to_string(key), value} end)
    }
  end

  defp json(binary) do
    case Jason.decode(binary) do
      {:ok, data} when is_map(data) -> {:ok, data}
      {:ok, _} -> invalid("the artifact is not a JSON object")
      {:error, _} -> invalid("the artifact is not valid JSON")
    end
  end

  defp check_top(data) do
    cond do
      Map.keys(data) -- @top_keys != [] ->
        invalid("unknown artifact fields: #{inspect(Map.keys(data) -- @top_keys)}")

      data["format"] != @format ->
        invalid("unknown artifact format #{inspect(data["format"])}")

      data["version"] != @version ->
        invalid("unsupported artifact version #{inspect(data["version"])}")

      not is_map(data["entries"]) ->
        invalid("artifact entries must be an object")

      true ->
        :ok
    end
  end

  defp check_entries(entries) do
    Enum.reduce_while(entries, :ok, fn {name, entry}, :ok ->
      case check_entry(name, entry) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp check_entry(name, %{"kind" => "predictor"} = entry) do
    cond do
      Map.keys(entry) -- @predictor_keys != [] ->
        invalid("entry #{inspect(name)} has unknown fields")

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
      Map.keys(entry) -- @value_keys != [] -> invalid("entry #{inspect(name)} has unknown fields")
      not is_binary(entry["fingerprint"]) -> invalid("entry #{inspect(name)} needs a fingerprint")
      not Map.has_key?(entry, "value") -> invalid("entry #{inspect(name)} needs a value")
      true -> :ok
    end
  end

  defp check_entry(name, _entry), do: invalid("entry #{inspect(name)} has an unknown kind")

  defp demo_shape?(%{"inputs" => inputs, "outputs" => outputs} = demo)
       when is_map(inputs) and is_map(outputs) and map_size(demo) == 2,
       do: true

  defp demo_shape?(_demo), do: false

  defp check_provenance(nil), do: {:ok, nil}

  defp check_provenance(provenance) when is_map(provenance) do
    keys = Enum.map(Map.keys(provenance), &to_string/1)

    cond do
      keys -- @provenance_keys != [] ->
        invalid("unknown provenance fields: #{inspect(keys -- @provenance_keys)}")

      not json_safe?(provenance) ->
        invalid("provenance must contain only JSON data")

      true ->
        {:ok, provenance}
    end
  end

  defp check_provenance(other),
    do: invalid("provenance must be an object, got: #{inspect(other)}")

  defp json_safe?(value) when is_map(value) and not is_struct(value),
    do: Enum.all?(value, fn {key, value} -> is_binary(key) and json_safe?(value) end)

  defp json_safe?(value) when is_list(value), do: Enum.all?(value, &json_safe?/1)

  defp json_safe?(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: true

  defp json_safe?(_value), do: false

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

  defp check(true, _message), do: :ok
  defp check(false, message), do: invalid(message)

  defp invalid(message), do: {:error, Error.Invalid.Definition.exception(message: message)}
end
