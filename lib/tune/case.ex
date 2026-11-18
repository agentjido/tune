defmodule Tune.Case do
  @moduledoc "One normalized input and expected result."

  alias Tune.Error
  alias Tune.Input
  alias Tune.Signature

  @enforce_keys [:id, :input]
  defstruct [:id, :input, :expected, metadata: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          input: term(),
          expected: term(),
          metadata: map()
        }

  @fields [:id, :input, :expected, :metadata]
  @row_fields %{id: Zoi.string(), input: Zoi.map(), expected: Zoi.map(), metadata: Zoi.map()}
  @program_schema Zoi.map(@row_fields)
  @program_comparison Zoi.map(Map.put(@row_fields, :id, Input.nonblank_string()))
  @generic_comparison Zoi.map(%{
                        id: Input.nonblank_string(),
                        input: Zoi.any(),
                        expected: Zoi.any(),
                        metadata: Zoi.map()
                      })

  @doc "Normalizes program rows against one typed signature."
  @spec normalize_all(Signature.t(), Enumerable.t()) :: {:ok, [t()]} | {:error, Exception.t()}
  def normalize_all(%Signature{} = signature, rows),
    do: normalize_program_rows(signature, rows, :evaluate)

  @doc false
  def compare_rows(%Signature{} = signature, rows),
    do: normalize_program_rows(signature, rows, :compare)

  def compare_rows(nil, rows), do: read_rows(rows, &normalize_generic_comparison/2)

  defp normalize_program_rows(signature, rows, mode) do
    read_rows(rows, fn row, index -> normalize_program(signature, row, index, mode) end)
  end

  defp read_rows(rows, normalize) do
    rows
    |> Stream.with_index()
    |> Enum.reduce_while({:ok, []}, fn {row, index}, {:ok, acc} ->
      case normalize.(row, index) do
        {:ok, tune_case} -> {:cont, {:ok, [tune_case | acc]}}
        {:error, error} -> {:halt, definition_error("row #{index}: #{Exception.message(error)}")}
      end
    end)
    |> case do
      {:ok, []} -> definition_error("the dataset is empty")
      {:ok, cases} -> cases |> Enum.reverse() |> check_ids()
      error -> error
    end
  rescue
    Protocol.UndefinedError -> definition_error("a dataset must implement Enumerable")
  end

  @doc "Returns the canonical key for one case input."
  @spec input_key(t()) :: String.t()
  def input_key(%__MODULE__{input: input}), do: Tune.CanonicalJSON.encode!(input)

  @doc false
  def normalize(%__MODULE__{} = row, _index), do: row

  def normalize(row, index) do
    tune_case = generic_case(row, index)
    %{tune_case | id: to_string(tune_case.id)}
  end

  defp generic_case(%__MODULE__{} = row, _index), do: row

  defp generic_case(%{} = row, index) do
    %__MODULE__{
      id: field(row, :id, Integer.to_string(index)),
      input: field(row, :input, row),
      expected: field(row, :expected),
      metadata: field(row, :metadata, %{})
    }
  end

  defp generic_case(row, index), do: %__MODULE__{id: Integer.to_string(index), input: row}

  defp normalize_generic_comparison(row, index) do
    fields = row |> generic_case(index) |> Map.from_struct()

    with {:ok, fields} <- Input.definition(@generic_comparison, fields, "comparison case") do
      {:ok, struct(__MODULE__, fields)}
    end
  end

  @doc false
  def field(row, key, default \\ nil),
    do: Map.get(row, key, Map.get(row, to_string(key), default))

  defp normalize_program(signature, %__MODULE__{} = tune_case, _index, :evaluate),
    do: validate_program_input(signature, tune_case)

  defp normalize_program(signature, %__MODULE__{} = tune_case, _index, :compare) do
    fields = Map.from_struct(tune_case)
    fields = if is_nil(tune_case.expected), do: Map.put(fields, :expected, %{}), else: fields
    parse_program_case(signature, fields, @program_comparison)
  end

  defp normalize_program(signature, %{} = row, index, mode) do
    defaults = %{id: Integer.to_string(index), expected: %{}, metadata: %{}}
    fields = Map.merge(defaults, Input.fields(row, @fields))
    schema = if mode == :compare, do: @program_comparison, else: @program_schema
    parse_program_case(signature, fields, schema)
  end

  defp normalize_program(_signature, _row, _index, _mode),
    do: definition_error("expected a case object")

  defp parse_program_case(signature, fields, schema) do
    with {:ok, fields} <- Input.definition(schema, fields, "program case") do
      validate_program_input(signature, struct(__MODULE__, fields))
    end
  end

  defp validate_program_input(signature, tune_case) do
    with {:ok, input} <- Signature.normalize_inputs(signature, tune_case.input) do
      {:ok, %{tune_case | input: input, expected: stringify(tune_case.expected)}}
    end
  end

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
