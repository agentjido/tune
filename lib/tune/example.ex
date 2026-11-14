defmodule Tune.Example do
  @moduledoc """
  One dataset row: program inputs, labels, and a stable row identity.

  Inputs are validated against the program signature once, when a dataset is
  normalized. Labels are never passed to the program; only the metric sees them.
  """

  alias Tune.Error
  alias Tune.Signature

  @enforce_keys [:id, :inputs, :labels]
  defstruct @enforce_keys

  @type t :: %__MODULE__{id: String.t(), inputs: map(), labels: map()}

  @doc """
  Normalizes a dataset against a program signature.

  Each row is an `Example`, or a map with `:inputs`, optional `:labels`, and
  optional `:id`. Rows without an id get their zero-based index. Ids must be
  unique. An empty dataset is an error.
  """
  @spec normalize_all(Signature.t(), list()) :: {:ok, [t()]} | {:error, Exception.t()}
  def normalize_all(%Signature{}, []), do: definition_error("the dataset is empty")

  def normalize_all(%Signature{} = signature, rows) when is_list(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {row, index}, {:ok, acc} ->
      case normalize(signature, row, index) do
        {:ok, example} -> {:cont, {:ok, [example | acc]}}
        {:error, error} -> {:halt, definition_error("row #{index}: #{Exception.message(error)}")}
      end
    end)
    |> then(fn
      {:ok, examples} -> check_ids(Enum.reverse(examples))
      error -> error
    end)
  end

  def normalize_all(%Signature{}, other),
    do: definition_error("a dataset must be a list, got: #{inspect(other)}")

  @doc "Returns the canonical JSON of an example's normalized inputs, used for exact overlap checks."
  @spec input_key(t()) :: String.t()
  def input_key(%__MODULE__{inputs: inputs}), do: canonical_json(inputs)

  @doc false
  @spec canonical_json(term()) :: String.t()
  def canonical_json(value), do: value |> canonical() |> Jason.encode!()

  defp canonical(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), canonical(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(value), do: value

  defp normalize(signature, %__MODULE__{} = example, _index) do
    with {:ok, inputs} <- Signature.normalize_inputs(signature, example.inputs) do
      {:ok, %{example | inputs: inputs}}
    end
  end

  defp normalize(signature, %{} = row, index) do
    inputs = Map.get(row, :inputs, Map.get(row, "inputs"))
    labels = Map.get(row, :labels, Map.get(row, "labels", %{}))
    id = Map.get(row, :id, Map.get(row, "id", Integer.to_string(index)))

    cond do
      not is_map(inputs) -> definition_error("inputs must be a map")
      not is_map(labels) -> definition_error("labels must be a map")
      not is_binary(id) -> definition_error("id must be a string")
      true -> build(signature, id, inputs, labels)
    end
  end

  defp normalize(_signature, other, _index), do: definition_error("invalid row #{inspect(other)}")

  defp build(signature, id, inputs, labels) do
    with {:ok, inputs} <- Signature.normalize_inputs(signature, inputs) do
      {:ok, %__MODULE__{id: id, inputs: inputs, labels: stringify(labels)}}
    end
  end

  defp stringify(labels), do: Map.new(labels, fn {key, value} -> {to_string(key), value} end)

  defp check_ids(examples) do
    case examples
         |> Enum.frequencies_by(& &1.id)
         |> Enum.find(fn {_id, count} -> count > 1 end) do
      nil -> {:ok, examples}
      {id, _} -> definition_error("duplicate row id #{inspect(id)}")
    end
  end

  defp definition_error(message),
    do: {:error, Error.Invalid.Definition.exception(message: message)}
end
