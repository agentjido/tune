defmodule Tune.Space.Integer do
  @moduledoc "An integer value space."
  @behaviour Tune.Space

  alias Tune.Space

  @enforce_keys [:min, :max, :step]
  defstruct [:min, :max, :step]

  @type t :: %__MODULE__{min: integer(), max: integer(), step: pos_integer()}

  @spec new(integer(), integer(), integer()) :: {:ok, t()} | {:error, Exception.t()}
  def new(first, last, step) when step != 0 do
    min = min(first, last)
    max = max(first, last)
    step = abs(step)

    if rem(max - min, step) == 0,
      do: {:ok, %__MODULE__{min: min, max: max, step: step}},
      else: invalid("integer range bounds must align with the step")
  end

  def new(_first, _last, _step), do: invalid("integer range step cannot be zero")

  @impl true
  def sample(space, state) do
    count = div(space.max - space.min, space.step) + 1
    {index, state} = Space.integer(state, count)
    {space.min + index * space.step, state}
  end

  @impl true
  def mutate(space, value, state) do
    {direction, state} = Space.integer(state, 2)
    delta = if direction == 0, do: -space.step, else: space.step
    {value |> Kernel.+(delta) |> max(space.min) |> min(space.max), state}
  end

  @impl true
  def crossover(space, left, right, state) do
    midpoint = round((left + right) / 2)
    value = space.min + round((midpoint - space.min) / space.step) * space.step
    {value |> max(space.min) |> min(space.max), state}
  end

  @impl true
  def valid?(space, value) do
    is_integer(value) and value >= space.min and value <= space.max and
      rem(value - space.min, space.step) == 0
  end

  defp invalid(message),
    do: {:error, Tune.Error.Invalid.Definition.exception(message: message)}
end
