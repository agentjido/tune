defmodule Tune.Artifact do
  @moduledoc "A versioned learned-value artifact with safe provenance."

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

  @keys ["version", "target_fingerprint", "parameters", "provenance"]
  @max_bytes 1_000_000

  @doc "Builds and validates an artifact from data."
  @spec new(map()) :: {:ok, t()} | {:error, Exception.t()}
  def new(attrs) when is_map(attrs) do
    value = struct(__MODULE__, attrs)

    case Zoi.parse(@schema, value) do
      {:ok, artifact} -> {:ok, artifact}
      {:error, errors} -> invalid(errors)
    end
  end

  @doc "Validates an artifact."
  @spec validate(t()) :: :ok | {:error, Exception.t()}
  def validate(%__MODULE__{} = artifact) do
    case Zoi.parse(@schema, artifact) do
      {:ok, _artifact} -> :ok
      {:error, errors} -> invalid(errors)
    end
  end

  @doc "Encodes a validated artifact as JSON."
  @spec encode(t()) :: {:ok, String.t()} | {:error, Exception.t()}
  def encode(%__MODULE__{} = artifact) do
    case validate(artifact) do
      :ok -> Jason.encode(to_data(artifact))
      error -> error
    end
  end

  @doc "Decodes and validates a JSON artifact."
  @spec decode(String.t()) :: {:ok, t()} | {:error, Exception.t()}
  def decode(json) when is_binary(json) do
    with :ok <- validate_size(json),
         {:ok, data} <- Jason.decode(json),
         :ok <- validate_keys(data),
         {:ok, artifact} <-
           new(%{
             version: data["version"],
             target_fingerprint: data["target_fingerprint"],
             parameters: data["parameters"],
             provenance: data["provenance"]
           }) do
      {:ok, artifact}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error,
         Tune.Error.Invalid.Definition.exception(
           message: "artifact is not valid JSON",
           details: error
         )}

      error ->
        error
    end
  end

  defp validate_size(json) when byte_size(json) <= @max_bytes, do: :ok

  defp validate_size(_json) do
    {:error,
     Tune.Error.Invalid.Definition.exception(
       message: "artifact is larger than #{@max_bytes} bytes"
     )}
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
    if Enum.sort(Map.keys(data)) == Enum.sort(@keys) do
      :ok
    else
      {:error,
       Tune.Error.Invalid.Definition.exception(
         message: "artifact has unknown or missing fields",
         details: Map.keys(data)
       )}
    end
  end

  defp validate_keys(_data) do
    {:error, Tune.Error.Invalid.Definition.exception(message: "artifact must be a JSON object")}
  end

  defp invalid(errors) do
    {:error,
     Tune.Error.Invalid.Definition.exception(
       message: "invalid Tune artifact",
       details: errors
     )}
  end
end
