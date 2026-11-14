defmodule Tune.Space do
  @moduledoc """
  A value space used by search strategies.

  Built-in descriptors are normalized once before search. Custom spaces are
  structs whose module implements this behaviour.
  """

  alias Tune.Error
  alias Tune.Space.Choice
  alias Tune.Space.Float
  alias Tune.Space.Integer
  alias Tune.Space.Subset
  alias Tune.Space.Text

  @type random_state :: :rand.state()

  @callback sample(struct(), random_state()) :: {term(), random_state()}
  @callback mutate(struct(), term(), random_state()) :: {term(), random_state()}
  @callback crossover(struct(), term(), term(), random_state()) :: {term(), random_state()}
  @callback valid?(struct(), term()) :: boolean()

  @doc "Normalizes a built-in descriptor or custom space."
  @spec new(term()) :: {:ok, struct()} | {:error, Exception.t()}
  def new(%Range{first: first, last: last, step: step})
      when is_integer(first) and is_integer(last) and is_integer(step),
      do: Integer.new(first, last, step)

  def new(%module{} = space) do
    if space_module?(module),
      do: {:ok, space},
      else: invalid("#{inspect(module)} does not implement Tune.Space")
  end

  def new({:float, min, max}), do: Float.new(min, max, false)
  def new({:log_float, min, max}), do: Float.new(min, max, true)
  def new({:subset, values}), do: Subset.new(values, 0, length(values))
  def new({:subset, values, min, max}), do: Subset.new(values, min, max)
  def new({:text, opts}) when is_list(opts), do: Text.new(opts)
  def new(values) when is_list(values), do: Choice.new(values)
  def new(other), do: invalid("invalid value space #{inspect(other)}")

  @doc false
  def sample(%module{} = space, state), do: module.sample(space, state)

  @doc false
  def mutate(%module{} = space, value, state), do: module.mutate(space, value, state)

  @doc false
  def crossover(%module{} = space, left, right, state),
    do: module.crossover(space, left, right, state)

  @doc false
  def valid?(%module{} = space, value), do: module.valid?(space, value)

  @doc false
  def uniform(state) do
    :rand.uniform_s(state)
  end

  @doc false
  def integer(state, count) when count > 0 do
    {value, state} = :rand.uniform_s(count, state)
    {value - 1, state}
  end

  defp space_module?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :sample, 2) and
      function_exported?(module, :mutate, 3) and function_exported?(module, :crossover, 4) and
      function_exported?(module, :valid?, 2)
  end

  defp invalid(message),
    do: {:error, Error.Invalid.Definition.exception(message: message)}
end
