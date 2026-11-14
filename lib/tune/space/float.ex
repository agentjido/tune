defmodule Tune.Space.Float do
  @moduledoc "A linear or logarithmic floating-point value space."
  @behaviour Tune.Space

  alias Tune.Space

  @enforce_keys [:min, :max, :log?]
  defstruct [:min, :max, :log?]

  @type t :: %__MODULE__{min: float(), max: float(), log?: boolean()}

  @spec new(number(), number(), boolean()) :: {:ok, t()} | {:error, Exception.t()}
  def new(min, max, log?)
      when is_number(min) and is_number(max) and min < max and is_boolean(log?) do
    if log? and min <= 0,
      do: invalid("a logarithmic float space requires a positive minimum"),
      else: {:ok, %__MODULE__{min: min / 1, max: max / 1, log?: log?}}
  end

  def new(_min, _max, _log?), do: invalid("a float space requires min < max")

  @impl true
  def sample(space, state) do
    {unit, state} = Space.uniform(state)

    value =
      if space.log? do
        :math.exp(:math.log(space.min) + unit * (:math.log(space.max) - :math.log(space.min)))
      else
        space.min + unit * (space.max - space.min)
      end

    {value, state}
  end

  @impl true
  def mutate(space, value, state) do
    {unit, state} = Space.uniform(state)
    scale = (unit - 0.5) * 0.2

    value =
      if space.log? do
        value * :math.exp(scale * (:math.log(space.max) - :math.log(space.min)))
      else
        value + scale * (space.max - space.min)
      end

    {value |> max(space.min) |> min(space.max), state}
  end

  @impl true
  def crossover(space, left, right, state) do
    {unit, state} = Space.uniform(state)
    value = left * unit + right * (1.0 - unit)
    {value |> max(space.min) |> min(space.max), state}
  end

  @impl true
  def valid?(space, value), do: is_number(value) and value >= space.min and value <= space.max

  defp invalid(message),
    do: {:error, Tune.Error.Invalid.Definition.exception(message: message)}
end
