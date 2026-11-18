defmodule Tune.Dataset do
  @moduledoc false

  def prefix(rows, nil), do: rows
  def prefix(rows, limit), do: Stream.take(rows, limit)

  def select(rows, nil), do: {Enum.to_list(rows), false}

  def select(rows, limit) do
    {selected, extra} = rows |> lookahead(limit) |> Enum.split(limit)
    {selected, extra != []}
  end

  def lookahead(rows, nil), do: rows
  def lookahead(rows, limit), do: prefix(rows, limit + 1)

  def split_chunk(chunk, nil), do: {chunk, false}

  def split_chunk(chunk, limit) do
    {selected, extra} = Enum.split_while(chunk, fn {_row, index} -> index < limit end)
    {selected, extra != []}
  end

  def capture_source(rows, %{on_dataset: callback} = limits, split)
      when is_function(callback, 3) do
    rows = Enum.to_list(rows)
    report(limits, split, :source, rows)
    rows
  end

  def capture_source(rows, _limits, _split), do: rows

  def report(%{on_dataset: callback}, split, stage, rows) when is_function(callback, 3) do
    callback.(split, stage, describe(rows))
  end

  def report(_limits, _split, _stage, _rows), do: :ok

  defp describe(rows) do
    fingerprint =
      rows
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    %{rows: length(rows), fingerprint: fingerprint}
  end
end
