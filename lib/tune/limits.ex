defmodule Tune.Limits do
  @moduledoc false

  alias Tune.Input

  @nonnegative Zoi.integer() |> Zoi.gte(0) |> Zoi.optional()
  @positive Zoi.integer() |> Zoi.positive() |> Zoi.optional()
  @fields [
    model_calls: @nonnegative,
    evaluations: @nonnegative,
    cases: @nonnegative,
    concurrency: @positive,
    row_timeout: @positive,
    row_calls: @positive,
    deadline: Zoi.union([Zoi.integer() |> Zoi.gte(0), Zoi.literal(:infinity)]) |> Zoi.optional(),
    steps: @nonnegative,
    seed: Zoi.integer() |> Zoi.optional()
  ]
  @schema Zoi.map(@fields, unrecognized_keys: :error)
  @string_keys Map.new(Keyword.keys(@fields), &{Atom.to_string(&1), &1})

  def cast(limits), do: Zoi.parse(@schema, limits)

  def workbench(limits) when is_map(limits) do
    limits = Map.new(limits, fn {key, value} -> {Map.get(@string_keys, key, key), value} end)
    Input.definition(@schema, limits, "limits")
  end
end
