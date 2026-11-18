defmodule Tune.UI.RecipeInput do
  @moduledoc false

  alias Tune.Input

  def rows(rows, split, parse) do
    rows
    |> Stream.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {row, index}, {:ok, acc} ->
      case parse.(row) do
        {:ok, value} ->
          {:cont, {:ok, [value | acc]}}

        {:error, error} ->
          {:halt, Input.invalid("#{split} row #{index}: #{Exception.message(error)}")}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end
end
