defmodule Tune.Space.Subset do
  @moduledoc "A bounded subset of a finite list."
  @behaviour Tune.Space

  alias Tune.Space

  @enforce_keys [:values, :min, :max]
  defstruct [:values, :min, :max]

  @type t :: %__MODULE__{values: [term()], min: non_neg_integer(), max: non_neg_integer()}

  @spec new(list(), non_neg_integer(), non_neg_integer()) ::
          {:ok, t()} | {:error, Exception.t()}
  def new(values, min, max)
      when is_list(values) and is_integer(min) and is_integer(max) and min >= 0 and min <= max do
    values = Enum.uniq(values)

    if max <= length(values),
      do: {:ok, %__MODULE__{values: values, min: min, max: max}},
      else: invalid("subset maximum exceeds the number of values")
  end

  def new(_values, _min, _max), do: invalid("invalid subset bounds")

  @impl true
  def sample(space, state) do
    {size_offset, state} = Space.integer(state, space.max - space.min + 1)
    take_random(space.values, space.min + size_offset, state)
  end

  @impl true
  def mutate(space, value, state) do
    missing = Enum.reject(space.values, &(&1 in value))

    cond do
      length(value) <= space.min and missing != [] ->
        add(value, missing, state)

      length(value) >= space.max ->
        remove(value, state)

      missing == [] ->
        remove(value, state)

      true ->
        {choice, state} = Space.integer(state, 2)
        if choice == 0, do: add(value, missing, state), else: remove(value, state)
    end
  end

  @impl true
  def crossover(space, left, right, state) do
    pool = Enum.uniq(left ++ right)
    size = length(left) |> max(space.min) |> min(space.max) |> min(length(pool))
    take_random(pool, size, state)
  end

  @impl true
  def valid?(space, value) when is_list(value) do
    value == Enum.uniq(value) and length(value) >= space.min and length(value) <= space.max and
      Enum.all?(value, &(&1 in space.values))
  end

  def valid?(_space, _value), do: false

  defp add(value, missing, state) do
    {index, state} = Space.integer(state, length(missing))
    {value ++ [Enum.at(missing, index)], state}
  end

  defp remove([], state), do: {[], state}

  defp remove(value, state) do
    {index, state} = Space.integer(state, length(value))
    {List.delete_at(value, index), state}
  end

  defp take_random(values, count, state) do
    Enum.reduce(1..count//1, {[], values, state}, fn _, {chosen, remaining, state} ->
      {index, state} = Space.integer(state, length(remaining))
      {item, remaining} = List.pop_at(remaining, index)
      {[item | chosen], remaining, state}
    end)
    |> then(fn {chosen, _remaining, state} -> {Enum.reverse(chosen), state} end)
  end

  defp invalid(message),
    do: {:error, Tune.Error.Invalid.Definition.exception(message: message)}
end
