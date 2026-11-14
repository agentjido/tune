defmodule Tune.Space.Text do
  @moduledoc "A bounded text space for simple evolutionary search."
  @behaviour Tune.Space

  alias Tune.Space

  @default_alphabet String.graphemes("abcdefghijklmnopqrstuvwxyz ")

  @enforce_keys [:alphabet, :min_length, :max_length]
  defstruct [:alphabet, :min_length, :max_length]

  @type t :: %__MODULE__{
          alphabet: [String.t()],
          min_length: non_neg_integer(),
          max_length: non_neg_integer()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def new(opts) do
    alphabet = Keyword.get(opts, :alphabet, @default_alphabet)
    min_length = Keyword.get(opts, :min_length, 0)
    max_length = Keyword.get(opts, :max_length, 80)

    if is_list(alphabet) and alphabet != [] and is_integer(min_length) and
         is_integer(max_length) and min_length >= 0 and min_length <= max_length do
      {:ok,
       %__MODULE__{
         alphabet: Enum.uniq(alphabet),
         min_length: min_length,
         max_length: max_length
       }}
    else
      invalid("invalid text space options")
    end
  end

  @impl true
  def sample(space, state) do
    {offset, state} = Space.integer(state, space.max_length - space.min_length + 1)
    chars(space, space.min_length + offset, state)
  end

  @impl true
  def mutate(space, value, state) do
    graphemes = String.graphemes(value)
    {operation, state} = Space.integer(state, 3)

    cond do
      operation == 0 and length(graphemes) < space.max_length -> insert(space, graphemes, state)
      operation == 1 and length(graphemes) > space.min_length -> delete(graphemes, state)
      graphemes != [] -> replace(space, graphemes, state)
      true -> insert(space, graphemes, state)
    end
  end

  @impl true
  def crossover(space, left, right, state) do
    left = String.graphemes(left)
    right = String.graphemes(right)
    {left_index, state} = Space.integer(state, length(left) + 1)
    {right_index, state} = Space.integer(state, length(right) + 1)

    value =
      (Enum.take(left, left_index) ++ Enum.drop(right, right_index))
      |> Enum.take(space.max_length)
      |> pad(space, state)

    {text, state} = value
    {Enum.join(text), state}
  end

  @impl true
  def valid?(space, value) when is_binary(value) do
    graphemes = String.graphemes(value)

    length(graphemes) >= space.min_length and length(graphemes) <= space.max_length and
      Enum.all?(graphemes, &(&1 in space.alphabet))
  end

  def valid?(_space, _value), do: false

  defp chars(space, count, state) do
    Enum.map_reduce(1..count//1, state, fn _, state ->
      {index, state} = Space.integer(state, length(space.alphabet))
      {Enum.at(space.alphabet, index), state}
    end)
    |> then(fn {chars, state} -> {Enum.join(chars), state} end)
  end

  defp insert(space, graphemes, state) do
    {position, state} = Space.integer(state, length(graphemes) + 1)
    {index, state} = Space.integer(state, length(space.alphabet))
    {List.insert_at(graphemes, position, Enum.at(space.alphabet, index)) |> Enum.join(), state}
  end

  defp delete(graphemes, state) do
    {position, state} = Space.integer(state, length(graphemes))
    {List.delete_at(graphemes, position) |> Enum.join(), state}
  end

  defp replace(space, graphemes, state) do
    {position, state} = Space.integer(state, length(graphemes))
    {index, state} = Space.integer(state, length(space.alphabet))
    {List.replace_at(graphemes, position, Enum.at(space.alphabet, index)) |> Enum.join(), state}
  end

  defp pad(graphemes, space, state) when length(graphemes) >= space.min_length,
    do: {graphemes, state}

  defp pad(graphemes, space, state) do
    {text, state} = chars(space, space.min_length - length(graphemes), state)
    {graphemes ++ String.graphemes(text), state}
  end

  defp invalid(message),
    do: {:error, Tune.Error.Invalid.Definition.exception(message: message)}
end
