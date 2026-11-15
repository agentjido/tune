defmodule Tune.JSON do
  @moduledoc false

  @spec encode_object!([{String.Chars.t(), term()}]) :: String.t()
  def encode_object!(pairs) when is_list(pairs) do
    pairs
    |> Enum.map(fn {key, value} -> [JSON.encode!(to_string(key)), ?:, JSON.encode!(value)] end)
    |> Enum.intersperse(?,)
    |> then(&IO.iodata_to_binary([?{, &1, ?}]))
  end

  @spec pretty_encode!(term()) :: String.t()
  def pretty_encode!(value), do: value |> pretty(0) |> IO.iodata_to_binary()

  @spec pretty_encode_object!([{String.Chars.t(), term()}]) :: String.t()
  def pretty_encode_object!(pairs) when is_list(pairs), do: pretty_object(pairs, 0)

  defp pretty(map, depth) when is_map(map) and not is_struct(map),
    do: pretty_object(Map.to_list(map), depth)

  defp pretty([], _depth), do: "[]"

  defp pretty(list, depth) when is_list(list) do
    indentation = indent(depth + 1)

    items =
      list
      |> Enum.map(&[indentation, pretty(&1, depth + 1)])
      |> Enum.intersperse(",\n")

    ["[\n", items, ?\n, indent(depth), ?]]
  end

  defp pretty(value, _depth), do: JSON.encode!(value)

  defp pretty_object([], _depth), do: "{}"

  defp pretty_object(pairs, depth) do
    indentation = indent(depth + 1)

    fields =
      pairs
      |> Enum.map(fn {key, value} ->
        [indentation, JSON.encode!(to_string(key)), ": ", pretty(value, depth + 1)]
      end)
      |> Enum.intersperse(",\n")

    IO.iodata_to_binary(["{\n", fields, ?\n, indent(depth), ?}])
  end

  defp indent(depth), do: String.duplicate("  ", depth)
end
