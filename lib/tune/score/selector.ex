defmodule Tune.Score.Selector do
  @moduledoc false

  alias Tune.Error
  alias Tune.Score

  @spec compile([Score.t()], term()) :: {:ok, term()} | {:error, Exception.t()}
  def compile([], _selector), do: invalid("at least one score is required")
  def compile([%Score{name: name}], nil), do: {:ok, {:score, name}}

  def compile(scores, nil) when length(scores) > 1,
    do: invalid("multiple scores require Tune.select/2")

  def compile(scores, {:score, name} = selector) do
    if Enum.any?(scores, &(&1.name == name)),
      do: {:ok, selector},
      else: invalid("unknown score #{inspect(name)}")
  end

  def compile(scores, {:weighted, weights} = selector) when is_map(weights) do
    names = MapSet.new(scores, & &1.name)

    valid? =
      map_size(weights) > 0 and
        Enum.all?(weights, fn {name, weight} ->
          MapSet.member?(names, name) and is_number(weight) and weight > 0 and
            scores |> score!(name) |> Map.fetch!(:range) |> Score.valid_range?()
        end)

    if valid?,
      do: {:ok, selector},
      else: invalid("weighted selection requires known scores with explicit ranges")
  end

  def compile(_scores, _selector), do: invalid("invalid score selector")

  @spec select(map(), [Score.t()], term()) :: number()
  def select(values, scores, {:score, name}) do
    orient(Map.fetch!(values, name), score!(scores, name).direction)
  end

  def select(values, scores, {:weighted, weights}) do
    total = weights |> Map.values() |> Enum.sum()

    Enum.sum(
      Enum.map(weights, fn {name, weight} ->
        weight * normalize(Map.fetch!(values, name), score!(scores, name))
      end)
    ) / total
  end

  @spec failure_values([Score.t()], term()) :: {:ok, map()} | :error
  def failure_values(scores, selector) do
    names = names(selector)

    if Enum.all?(names, &is_number(score!(scores, &1).failure_score)) do
      {:ok, Map.new(scores, &{&1.name, &1.failure_score})}
    else
      :error
    end
  end

  @spec failure_score([Score.t()], term()) :: number() | nil
  def failure_score(scores, selector) do
    case failure_values(scores, selector) do
      {:ok, values} -> select(values, scores, selector)
      :error -> nil
    end
  end

  @spec names(term()) :: [atom()]
  def names({:score, name}), do: [name]
  def names({:weighted, weights}), do: Map.keys(weights)

  defp normalize(value, %Score{range: {low, high}, direction: direction}) do
    normalized = (value - low) / (high - low)
    if direction == :maximize, do: normalized, else: 1.0 - normalized
  end

  defp orient(value, :maximize), do: value
  defp orient(value, :minimize), do: -value
  defp score!(scores, name), do: Enum.find(scores, &(&1.name == name))

  defp invalid(message),
    do: {:error, Error.Invalid.Option.exception(option: :selector, message: message)}
end
