defmodule Tune.Case do
  @moduledoc "One normalized input and expected result."

  alias Tune.Error
  alias Tune.Signature

  @enforce_keys [:id, :input]
  defstruct [:id, :input, :expected, metadata: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          input: term(),
          expected: term(),
          metadata: map()
        }

  @doc "Normalizes program rows against one typed signature."
  @spec normalize_all(Signature.t(), Enumerable.t()) :: {:ok, [t()]} | {:error, Exception.t()}
  def normalize_all(%Signature{} = signature, rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {row, index}, {:ok, acc} ->
      case normalize_program(signature, row, index) do
        {:ok, tune_case} -> {:cont, {:ok, [tune_case | acc]}}
        {:error, error} -> {:halt, definition_error("row #{index}: #{Exception.message(error)}")}
      end
    end)
    |> then(fn
      {:ok, []} -> definition_error("the dataset is empty")
      {:ok, cases} -> cases |> Enum.reverse() |> check_ids()
      error -> error
    end)
  rescue
    Protocol.UndefinedError -> definition_error("a dataset must implement Enumerable")
  end

  @doc "Returns the canonical key for one case input."
  @spec input_key(t()) :: String.t()
  def input_key(%__MODULE__{input: input}), do: Tune.CanonicalJSON.encode!(input)

  defp normalize_program(signature, %__MODULE__{} = tune_case, _index) do
    with {:ok, input} <- Signature.normalize_inputs(signature, tune_case.input) do
      {:ok, %{tune_case | input: input, expected: stringify(tune_case.expected)}}
    end
  end

  defp normalize_program(signature, %{} = row, index) do
    input = Map.get(row, :input, Map.get(row, "input"))
    expected = Map.get(row, :expected, Map.get(row, "expected", %{}))

    id = Map.get(row, :id, Map.get(row, "id", Integer.to_string(index)))
    metadata = Map.get(row, :metadata, Map.get(row, "metadata", %{}))

    cond do
      not is_map(input) ->
        definition_error("input must be a map")

      not is_map(expected) ->
        definition_error("expected must be a map")

      not is_binary(id) ->
        definition_error("id must be a string")

      not is_map(metadata) ->
        definition_error("metadata must be a map")

      true ->
        normalize_program(
          signature,
          %__MODULE__{id: id, input: input, expected: expected, metadata: metadata},
          index
        )
    end
  end

  defp normalize_program(_signature, other, _index),
    do: definition_error("invalid row #{inspect(other)}")

  defp stringify(nil), do: %{}
  defp stringify(expected), do: Map.new(expected, fn {key, value} -> {to_string(key), value} end)

  defp check_ids(cases) do
    case cases
         |> Enum.frequencies_by(& &1.id)
         |> Enum.find(fn {_id, count} -> count > 1 end) do
      nil -> {:ok, cases}
      {id, _} -> definition_error("duplicate row id #{inspect(id)}")
    end
  end

  defp definition_error(message),
    do: {:error, Error.Invalid.Definition.exception(message: message)}
end
