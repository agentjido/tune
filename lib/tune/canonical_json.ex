defmodule Tune.CanonicalJSON do
  @moduledoc false

  @spec encode!(term()) :: String.t()
  def encode!(value), do: value |> encode() |> IO.iodata_to_binary()

  defp encode(map) when is_map(map) and not is_struct(map) do
    fields =
      map
      |> Enum.map(fn {key, value} -> {to_string(key), value} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, value} -> [JSON.encode!(key), ?:, encode(value)] end)
      |> Enum.intersperse(?,)

    [?{, fields, ?}]
  end

  defp encode(list) when is_list(list),
    do: [?[, Enum.intersperse(Enum.map(list, &encode/1), ?,), ?]]

  defp encode(value), do: JSON.encode!(value)
end
