defmodule Tune.Artifact do
  @moduledoc "A versioned learned-value artifact with safe provenance."

  alias Tune.Artifact.Generic
  alias Tune.Artifact.Program
  alias Tune.CanonicalJSON
  alias Tune.Error
  alias Tune.Input
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
  @decode_limit Zoi.union([Zoi.integer() |> Zoi.gte(0), Zoi.literal(:infinity)])
  @decode_options Zoi.keyword(
                    max_bytes: @decode_limit |> Zoi.default(@max_bytes),
                    max_entries: @decode_limit |> Zoi.default(@max_entries)
                  )
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
  def new(attrs) when is_map(attrs), do: validate_artifact(struct(__MODULE__, attrs))

  @doc false
  @spec from_result(Result.t()) :: {:ok, t()} | {:error, Exception.t()}
  def from_result(%Result{metadata: %{strategy: :genetic, genome?: true}} = result) do
    with {:ok, parameters} <- Generic.project(result.parameters) do
      new(%{
        version: @version,
        target_fingerprint: Generic.genome_fingerprint(result.value),
        parameters: parameters,
        provenance: provenance(result, "genome")
      })
    end
  end

  def from_result(%Result{metadata: %{strategy: strategy}} = result)
      when strategy in [:genetic, :grid] do
    with {:ok, parameters} <- Generic.project(result.parameters) do
      new(%{
        version: @version,
        target_fingerprint: Generic.target_fingerprint(parameters),
        parameters: parameters,
        provenance: provenance(result, "generic")
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
        provenance: provenance(result, "program")
      })
    end
  end

  @doc "Validates an artifact."
  @spec validate(t()) :: :ok | {:error, Exception.t()}
  def validate(%__MODULE__{} = artifact) do
    with {:ok, _artifact} <- validate_artifact(artifact), do: :ok
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
    with {:ok, opts} <- Input.options(@decode_options, opts, :artifact, :first),
         :ok <- check_size(json, opts[:max_bytes]),
         {:ok, data} <- json(json),
         :ok <- validate_keys(data),
         :ok <- check_entries(data["parameters"], opts[:max_entries]) do
      new(Input.fields(data, [:version, :target_fingerprint, :parameters, :provenance]))
    end
  end

  @doc false
  @spec apply(t(), term()) :: {:ok, term()} | {:error, Exception.t()}
  def apply(%__MODULE__{} = artifact, fresh_target) do
    with {:ok, artifact} <- validate_artifact(artifact) do
      case artifact.provenance["kind"] do
        "program" ->
          apply_program(artifact, fresh_target)

        "generic" ->
          Generic.apply(fresh_target, artifact.parameters, artifact.target_fingerprint)

        "genome" ->
          Generic.apply_genome(fresh_target, artifact.parameters, artifact.target_fingerprint)

        _ ->
          invalid("artifact provenance needs a known kind")
      end
    end
  end

  defp apply_program(artifact, fresh_target) do
    with {:ok, fingerprint} <- Program.target_fingerprint(fresh_target),
         true <- fingerprint == artifact.target_fingerprint,
         {:ok, updated} <- Program.apply_validated(fresh_target, artifact.parameters) do
      {:ok, updated}
    else
      false -> invalid("artifact was learned for a different program contract")
      error -> error
    end
  end

  defp validate_artifact(value) do
    with {:ok, artifact} <- Input.definition(@schema, value, "invalid Tune artifact"),
         :ok <- validate_version(artifact),
         :ok <- validate_provenance(artifact.provenance),
         :ok <- validate_parameters(artifact) do
      {:ok, artifact}
    end
  end

  defp validate_parameters(%__MODULE__{provenance: %{"kind" => "program"}, parameters: entries}),
    do: Program.validate_entries(entries)

  defp validate_parameters(%__MODULE__{provenance: %{"kind" => "generic"}}), do: :ok

  defp validate_parameters(%__MODULE__{provenance: %{"kind" => "genome"}, parameters: parameters}) do
    check(
      match?(%{"genome" => _}, parameters) and map_size(parameters) == 1,
      "a genome artifact requires one genome value"
    )
  end

  defp validate_parameters(_artifact), do: invalid("artifact provenance needs a known kind")

  defp validate_version(%__MODULE__{version: @version}), do: :ok

  defp validate_version(%__MODULE__{version: version}),
    do: invalid("unsupported version #{inspect(version)}")

  defp validate_provenance(provenance) do
    case Map.keys(provenance) -- @provenance_keys do
      [] -> :ok
      unknown -> invalid("unknown provenance fields: #{inspect(unknown)}")
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

  defp check_size(json, limit),
    do: check(byte_size(json) <= limit, "artifact is larger than #{limit} bytes")

  defp check_entries(entries, limit) when is_map(entries),
    do: check(map_size(entries) <= limit, "artifact has more than #{limit} parameters")

  defp check_entries(_entries, _limit), do: :ok

  defp provenance(%Result{} = result, kind) do
    metadata = result.metadata
    notes = Map.get(metadata, :notes, %{})
    datasets = Map.get(metadata, :datasets, %{})
    best = result.best
    evaluation = best && best.evaluation
    summary = evaluation && Tune.Evaluation.summary(evaluation, :objective)

    %{
      "kind" => kind,
      "source" => "Tune.tune/1",
      "models" => Map.get(metadata, :models, %{}),
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

  defp check(true, _message), do: :ok
  defp check(false, message), do: invalid(message)

  defp invalid(message, details \\ nil),
    do: {:error, Error.Invalid.Definition.exception(message: message, details: details)}
end
