defmodule Tune.Space.Choice do
  @moduledoc "A finite choice space."
  @behaviour Tune.Space

  alias Tune.Space

  @enforce_keys [:values]
  defstruct [:values]

  @type t :: %__MODULE__{values: [term()]}

  @spec new(list()) :: {:ok, t()} | {:error, Exception.t()}
  def new([]), do: invalid("a choice space cannot be empty")
  def new(values) when is_list(values), do: {:ok, %__MODULE__{values: Enum.uniq(values)}}

  @impl true
  def sample(space, state) do
    {index, state} = Space.integer(state, length(space.values))
    {Enum.at(space.values, index), state}
  end

  @impl true
  def mutate(space, value, state) do
    alternatives = Enum.reject(space.values, &(&1 == value))

    if alternatives == [],
      do: {value, state},
      else: sample(%{space | values: alternatives}, state)
  end

  @impl true
  def crossover(_space, left, right, state) do
    {pick, state} = Space.integer(state, 2)
    {if(pick == 0, do: left, else: right), state}
  end

  @impl true
  def valid?(space, value), do: value in space.values

  defp invalid(message),
    do: {:error, Tune.Error.Invalid.Definition.exception(message: message)}
end
