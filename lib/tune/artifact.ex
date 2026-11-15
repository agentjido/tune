defmodule Tune.Artifact do
  @moduledoc "A versioned learned-value artifact with safe provenance."

  alias Tune.Artifact.Generic
  alias Tune.Artifact.Program
  alias Tune.CanonicalJSON
  alias Tune.Error
  alias Tune.ModelConfig
  alias Tune.Result

  @enforce_keys [:version, :target_fingerprint, :parameters]
  defstruct [:version, :target_fingerprint, :parameters, provenance: %{}]

  @schema Zoi.struct(__MODULE__, %{
            version: Zoi.integer() |> Zoi.positive(),
            target_fingerprint: Zoi.string() |> Zoi.min(1),
            parameters: Zoi.map(Zoi.string(), Zoi.json()),
            provenance: Zoi.map(Zoi.string(), Zoi.json())
          })

  @type t :: %__MODULE__{
          version: pos_integer(),
          target_fingerprint: String.t(),
          parameters: map(),
          provenance: map()
        }

  @version 1
  @keys ["version", "target_fingerprint", "parameters", "provenance"]
  @max_bytes 5_000_000
  @max_entries 1_000
  @provenance_keys [
    "kind",
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

  @doc "Builds and validates an artifact from data."
  @spec new(map()) :: {:ok, t()} | {:error, Exception.t()}
  def new(attrs) when is_map(attrs) do
    value = struct(__MODULE__, attrs)

    with {:ok, artifact} <- parse(value),
         :ok <- validate_version(artifact),
         :ok <- validate_provenance(artifact.provenance),
         :ok <- validate_parameters(artifact) do
      {:ok, artifact}
    end
  end

  @doc "Builds one artifact from a completed tuning result."
  @spec from_result(Result.t()) :: {:ok, t()} | {:error, Exception.t()}
  def from_result(%Result{metadata: %{strategy: :genetic}} = result) do
    with {:ok, parameters} <- Generic.project(result.parameters) do
      new(%{
        version: @version,
        target_fingerprint: Generic.target_fingerprint(parameters),
        parameters: parameters,
        provenance:
          provenance(
            source: "Tune.tune/1",
            report: result,
            kind: "generic",
            models: Map.get(result.metadata, :models, %{})
          )
      })
    end
  end

  def from_result(%Result{} = result) do
    with {:ok, parameters} <- Program.project(result.value),
         {:ok, fingerprint} <- Program.target_fingerprint(result.value) do
      new(%{
        version: @version,
        target_fingerprint: fingerprint,
        parameters: parameters,
        provenance:
          provenance(
            source: "Tune.tune/1",
            report: result,
            kind: "program",
            models: Map.get(result.metadata, :models, %{})
          )
      })
    end
  end

  @doc false
  @spec dump(Tune.Program.t(), keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def dump(program, opts \\ []) do
    with {:ok, parameters} <- Program.project(program),
         {:ok, fingerprint} <- Program.target_fingerprint(program),
         provenance <- Keyword.get(opts, :provenance, %{}),
         provenance <- Map.put_new(provenance, "kind", "program") do
      new(%{
        version: @version,
        target_fingerprint: fingerprint,
        parameters: parameters,
        provenance: provenance
      })
    end
  end

  @doc "Validates an artifact."
  @spec validate(t()) :: :ok | {:error, Exception.t()}
  def validate(%__MODULE__{} = artifact) do
    with {:ok, _artifact} <- parse(artifact),
         :ok <- validate_version(artifact),
         :ok <- validate_provenance(artifact.provenance) do
      validate_parameters(artifact)
    end
  end

  @doc "Encodes a validated artifact as canonical JSON."
  @spec encode(t()) :: {:ok, String.t()} | {:error, Exception.t()}
  def encode(%__MODULE__{} = artifact) do
    with :ok <- validate(artifact) do
      {:ok, artifact |> to_data() |> CanonicalJSON.encode!()}
    end
  end

  @doc "Decodes and validates a JSON artifact."
  @spec decode(String.t(), keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def decode(json, opts \\ []) when is_binary(json) do
    max_bytes = Keyword.get(opts, :max_bytes, @max_bytes)
    max_entries = Keyword.get(opts, :max_entries, @max_entries)

    with :ok <- check(byte_size(json) <= max_bytes, "artifact is larger than #{max_bytes} bytes"),
         {:ok, data} <- json(json),
         :ok <- validate_keys(data),
         :ok <-
           check(
             is_map(data["parameters"]) and map_size(data["parameters"]) <= max_entries,
             "artifact has more than #{max_entries} parameters"
           ) do
      new(%{
        version: data["version"],
        target_fingerprint: data["target_fingerprint"],
        parameters: data["parameters"],
        provenance: data["provenance"]
      })
    end
  end

  @doc "Validates and applies an artifact to fresh application code."
  @spec apply(t(), term()) :: {:ok, term()} | {:error, Exception.t()}
  def apply(%__MODULE__{} = artifact, fresh_target) do
    with :ok <- validate(artifact) do
      case artifact.provenance["kind"] do
        "program" -> apply_program(artifact, fresh_target)
        "generic" -> Generic.apply(fresh_target, artifact.parameters, artifact.target_fingerprint)
        _ -> invalid("artifact provenance needs a known kind")
      end
    end
  end

  @doc false
  @spec fingerprint(Tune.Predictor.t() | Tune.Parameter.t()) :: String.t()
  defdelegate fingerprint(parameter), to: Program

  @doc false
  @spec provenance(keyword()) :: map()
  def provenance(opts) do
    report = Keyword.get(opts, :report)

    base = %{
      "kind" => Keyword.get(opts, :kind, "program"),
      "source" => Keyword.get(opts, :source),
      "models" => describe_models(Keyword.get(opts, :models, []))
    }

    if report, do: Map.merge(base, report_provenance(report)), else: base
  end

  defp apply_program(artifact, fresh_target) do
    with {:ok, fingerprint} <- Program.target_fingerprint(fresh_target),
         true <- fingerprint == artifact.target_fingerprint,
         {:ok, updated} <- Program.apply(fresh_target, artifact.parameters) do
      {:ok, updated}
    else
      false -> invalid("artifact was learned for a different program contract")
      error -> error
    end
  end

  defp validate_parameters(%__MODULE__{provenance: %{"kind" => "program"}, parameters: entries}),
    do: Program.validate_entries(entries)

  defp validate_parameters(%__MODULE__{provenance: %{"kind" => "generic"}}), do: :ok
  defp validate_parameters(_artifact), do: invalid("artifact provenance needs a known kind")

  defp validate_version(%__MODULE__{version: @version}), do: :ok

  defp validate_version(%__MODULE__{version: version}),
    do: invalid("unsupported version #{inspect(version)}")

  defp validate_provenance(provenance) when is_map(provenance) do
    keys = Map.keys(provenance)

    cond do
      Enum.any?(keys, &(not is_binary(&1))) ->
        invalid("artifact provenance keys must be strings")

      keys -- @provenance_keys != [] ->
        invalid("unknown provenance fields: #{inspect(keys -- @provenance_keys)}")

      not json_safe?(provenance) ->
        invalid("provenance must contain only JSON data")

      true ->
        :ok
    end
  end

  defp validate_provenance(_provenance), do: invalid("artifact provenance must be an object")

  defp parse(value) do
    case Zoi.parse(@schema, value) do
      {:ok, artifact} -> {:ok, artifact}
      {:error, errors} -> invalid("invalid Tune artifact", errors)
    end
  end

  defp json(binary) do
    case JSON.decode(binary) do
      {:ok, data} when is_map(data) -> {:ok, data}
      {:ok, _data} -> invalid("artifact must be a JSON object")
      {:error, error} -> invalid("artifact is not valid JSON", error)
    end
  end

  defp to_data(artifact) do
    %{
      "version" => artifact.version,
      "target_fingerprint" => artifact.target_fingerprint,
      "parameters" => artifact.parameters,
      "provenance" => artifact.provenance
    }
  end

  defp validate_keys(data) when is_map(data) do
    if Enum.sort(Map.keys(data)) == Enum.sort(@keys),
      do: :ok,
      else: invalid("artifact has unknown or missing fields", Map.keys(data))
  end

  defp describe_models(models) do
    Map.new(models, fn
      {role, %ModelConfig{} = config} -> {to_string(role), ModelConfig.describe(config)}
      {role, value} -> {to_string(role), value}
    end)
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

  defp json_safe?(value) when is_map(value) and not is_struct(value),
    do: Enum.all?(value, fn {key, item} -> is_binary(key) and json_safe?(item) end)

  defp json_safe?(value) when is_list(value), do: Enum.all?(value, &json_safe?/1)

  defp json_safe?(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: true

  defp json_safe?(_value), do: false

  defp check(true, _message), do: :ok
  defp check(false, message), do: invalid(message)

  defp invalid(message, details \\ nil),
    do: {:error, Error.Invalid.Definition.exception(message: message, details: details)}
end
