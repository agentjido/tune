defmodule Tune.Replay do
  @moduledoc false

  alias Tune.Case
  alias Tune.Input

  @enforce_keys [:input, :output]
  defstruct [:id, :input, :output, :expected, metadata: %{}]

  @fields [:id, :input, :output, :expected, :metadata]
  @schema Zoi.map(%{
            id:
              Zoi.any()
              |> Zoi.transform({__MODULE__, :normalize_id, []})
              |> Zoi.optional(),
            input: Zoi.any(),
            output: Zoi.any(),
            expected: Zoi.any() |> Zoi.optional(),
            metadata: Zoi.map() |> Zoi.default(%{})
          })

  def study(rows, opts) do
    tune = Tune.new(:saved_responses, opts)
    tune = %{tune | runner: :replay}

    Tune.data(tune,
      test: fn ->
        source = resolve(rows)

        if Enumerable.impl_for(source) do
          Stream.with_index(source, &saved_case/2)
        else
          source
        end
      end
    )
  end

  def output(%Case{metadata: %{saved_output: result}}), do: result
  def output(%Case{}), do: Input.invalid("a saved row needs input and output")

  def parse(%__MODULE__{} = row), do: {:ok, row}

  def parse(%{} = row) do
    with {:ok, fields} <- Input.definition(@schema, Input.fields(row, @fields), "saved row") do
      {:ok, struct(__MODULE__, fields)}
    end
  end

  def parse(row), do: Input.definition(@schema, row, "saved row")

  def to_map(%__MODULE__{} = row) do
    values = %{
      input: row.input,
      output: row.output,
      expected: row.expected,
      metadata: row.metadata
    }

    if row.id, do: Map.put(values, :id, row.id), else: values
  end

  def normalize_id(value, _opts) do
    case Case.normalize_id(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, "must be convertible to a string"}
    end
  end

  defp saved_case(row, index) do
    case parse(row) do
      {:ok, saved} ->
        %Case{
          id: saved.id || Integer.to_string(index),
          input: saved.input,
          expected: saved.expected,
          metadata: Map.put(saved.metadata, :saved_output, {:ok, saved.output})
        }

      {:error, error} ->
        %Case{id: fallback_id(row, index), input: row, metadata: %{saved_output: {:error, error}}}
    end
  end

  defp fallback_id(%{} = row, index) do
    case normalize_id(Case.field(row, :id, index), []) do
      {:ok, id} -> id
      {:error, _} -> Integer.to_string(index)
    end
  end

  defp fallback_id(_row, index), do: Integer.to_string(index)

  defp resolve(factory) when is_function(factory, 0), do: factory.()
  defp resolve(rows), do: rows
end
