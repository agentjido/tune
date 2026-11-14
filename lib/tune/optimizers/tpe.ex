defmodule Tune.Optimizers.TPE do
  @moduledoc """
  A categorical Tree-structured Parzen Estimator.

  Each dimension is a categorical choice `0..n-1`. The first `n_startup`
  suggestions are uniform. After that, observations are split into a good
  group (the best `min(ceil(gamma * n), 25)` scores, higher is better) and a
  bad group. For each dimension independently, smoothed category densities
  `l(x)` and `g(x)` are computed with a uniform prior of weight `prior_weight`;
  `n_candidates` values are sampled from `l` and the one with the highest
  `l(x) / g(x)` is chosen, earliest on ties.

  This follows the documented behavior of Optuna's independent categorical TPE
  sampler. It does not reproduce Optuna's random number stream, multivariate
  mode, or Parzen weighting of older trials.
  """

  alias Tune.Search.Context

  defstruct space: %{}, n_startup: 10, gamma: 0.1, prior_weight: 1.0, n_candidates: 24

  @type t :: %__MODULE__{
          space: %{String.t() => pos_integer()},
          n_startup: non_neg_integer(),
          gamma: float(),
          prior_weight: float(),
          n_candidates: pos_integer()
        }

  @type choice :: %{String.t() => non_neg_integer()}

  @doc "Builds a sampler for a space of dimension name to category count."
  @spec new(%{String.t() => pos_integer()}, keyword()) :: t()
  def new(space, opts \\ []) do
    struct!(__MODULE__, Keyword.put(opts, :space, space))
  end

  @doc "Suggests one choice from `{choice, score}` observations."
  @spec suggest(t(), [{choice(), number()}], Context.t()) :: {choice(), Context.t()}
  def suggest(%__MODULE__{} = tpe, observations, ctx) do
    if length(observations) < tpe.n_startup do
      uniform(tpe, ctx)
    else
      modeled(tpe, observations, ctx)
    end
  end

  @doc false
  @spec densities(t(), [{choice(), number()}]) :: %{String.t() => {[float()], [float()]}}
  def densities(%__MODULE__{} = tpe, observations) do
    {good, bad} = split(tpe, observations)

    Map.new(tpe.space, fn {name, n} ->
      {name, {density(good, name, n, tpe.prior_weight), density(bad, name, n, tpe.prior_weight)}}
    end)
  end

  defp uniform(tpe, ctx) do
    tpe.space
    |> Enum.sort()
    |> Enum.reduce({%{}, ctx}, fn {name, n}, {acc, ctx} ->
      {value, ctx} = Context.uniform(ctx, n)
      {Map.put(acc, name, value), ctx}
    end)
  end

  defp modeled(tpe, observations, ctx) do
    densities = densities(tpe, observations)

    tpe.space
    |> Enum.sort()
    |> Enum.reduce({%{}, ctx}, fn {name, _n}, {acc, ctx} ->
      {l, g} = Map.fetch!(densities, name)
      {candidates, ctx} = sample_many(l, tpe.n_candidates, ctx)

      best =
        candidates
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.max_by(fn x -> Enum.at(l, x) / Enum.at(g, x) end)

      {Map.put(acc, name, best), ctx}
    end)
  end

  defp split(tpe, observations) do
    sorted =
      Enum.sort_by(Enum.with_index(observations), fn {{_choice, score}, index} ->
        {-score, index}
      end)

    n_good = max(min(ceil(tpe.gamma * length(observations)), 25), 1)
    {good, bad} = Enum.split(sorted, n_good)
    {Enum.map(good, &elem(elem(&1, 0), 0)), Enum.map(bad, &elem(elem(&1, 0), 0))}
  end

  defp density(choices, name, n, prior_weight) do
    counts = Enum.frequencies(Enum.map(choices, &Map.fetch!(&1, name)))
    total = length(choices) + prior_weight
    Enum.map(0..(n - 1), fn x -> (Map.get(counts, x, 0) + prior_weight / n) / total end)
  end

  defp sample_many(weights, count, ctx) do
    Enum.map_reduce(1..count, ctx, fn _, ctx ->
      {r, ctx} = Context.random(ctx)
      {pick(weights, r * Enum.sum(weights)), ctx}
    end)
  end

  defp pick(weights, target) do
    weights
    |> Enum.with_index()
    |> Enum.reduce_while(target, fn {weight, index}, left ->
      if left < weight, do: {:halt, {:index, index}}, else: {:cont, left - weight}
    end)
    |> case do
      {:index, index} -> index
      _ -> length(weights) - 1
    end
  end
end
