defmodule Tune.Demo do
  @moduledoc """
  One demonstration: complete inputs and outputs for a signature.

  Demonstrations are learnable predictor data. Both maps are validated against
  the signature they are used with.
  """

  alias Tune.Error
  alias Tune.Signature

  @enforce_keys [:inputs, :outputs]
  defstruct @enforce_keys

  @type t :: %__MODULE__{inputs: map(), outputs: map()}

  @doc "Normalizes one demonstration against a signature."
  @spec new(Signature.t(), t() | map()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%Signature{} = signature, %__MODULE__{inputs: inputs, outputs: outputs}),
    do: new(signature, %{inputs: inputs, outputs: outputs})

  def new(%Signature{} = signature, %{} = demo) do
    with {:ok, inputs} <- fetch(demo, :inputs),
         {:ok, outputs} <- fetch(demo, :outputs),
         {:ok, inputs} <- normalize_inputs(signature, inputs),
         {:ok, outputs} <- normalize_outputs(signature, outputs) do
      {:ok, %__MODULE__{inputs: inputs, outputs: outputs}}
    end
  end

  def new(%Signature{}, other), do: definition_error("invalid demonstration: #{inspect(other)}")

  @doc "Normalizes a list of demonstrations, stopping at the first invalid one."
  @spec new_list(Signature.t(), list()) :: {:ok, [t()]} | {:error, Exception.t()}
  def new_list(%Signature{} = signature, demos) when is_list(demos) do
    demos
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {demo, index}, {:ok, acc} ->
      case new(signature, demo) do
        {:ok, demo} ->
          {:cont, {:ok, [demo | acc]}}

        {:error, error} ->
          {:halt, definition_error("demonstration #{index}: #{Exception.message(error)}")}
      end
    end)
    |> then(fn
      {:ok, demos} -> {:ok, Enum.reverse(demos)}
      error -> error
    end)
  end

  def new_list(%Signature{}, other),
    do: definition_error("demonstrations must be a list, got: #{inspect(other)}")

  defp fetch(demo, key) do
    case Map.get(demo, key, Map.get(demo, Atom.to_string(key))) do
      %{} = value -> {:ok, value}
      other -> definition_error("demonstration #{key} must be a map, got: #{inspect(other)}")
    end
  end

  defp normalize_inputs(signature, inputs) do
    case Signature.normalize_inputs(signature, inputs) do
      {:ok, inputs} -> {:ok, inputs}
      {:error, error} -> definition_error(Exception.message(error))
    end
  end

  defp normalize_outputs(signature, outputs) do
    names = Signature.output_names(signature)

    normalized =
      Map.new(outputs, fn
        {key, value} when is_atom(key) -> {Atom.to_string(key), value}
        pair -> pair
      end)

    cond do
      map_size(normalized) != map_size(outputs) ->
        definition_error("demonstration outputs repeat a field")

      Map.keys(normalized) -- names != [] ->
        definition_error("demonstration outputs contain undeclared fields")

      true ->
        case Signature.validate_outputs(signature, normalized) do
          {:ok, outputs} -> {:ok, outputs}
          {:error, errors} -> definition_error(Signature.format_errors("invalid outputs", errors))
        end
    end
  end

  defp definition_error(message),
    do: {:error, Error.Invalid.Definition.exception(message: message)}
end
