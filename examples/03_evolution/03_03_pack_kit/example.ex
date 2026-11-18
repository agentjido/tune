defmodule Tune.Examples.Packing do
  @moduledoc "Evolve a feasible kit using a binary genome."

  @items [{2, 3}, {3, 4}, {4, 5}, {5, 8}]

  def packing do
    Tune.new([1, 0, 0, 0], run: &pack/1)
    |> Tune.data(validation: [:kit])
    |> Tune.score(:value, & &1.value)
    |> Tune.search(:genetic,
      initial_population: [[1, 0, 0, 0], [0, 0, 0, 1], [1, 1, 1, 1], [0, 1, 0, 0]],
      tournament_size: 2,
      generations: 15,
      mutation_rate: 1,
      crossover_rate: 1,
      crossover: fn left, right, rng ->
        {cut, rng} = :rand.uniform_s(3, rng)
        {Enum.take(left, cut) ++ Enum.drop(right, cut), rng}
      end,
      mutate: fn bits, rng ->
        {position, rng} = :rand.uniform_s(length(bits), rng)
        {List.update_at(bits, position - 1, &(1 - &1)), rng}
      end,
      target_score: 11
    )
    |> Tune.limit(evaluations: 64, seed: 9)
    |> Tune.tune()
  end

  defp pack(bits) do
    {weight, value} =
      Enum.zip_reduce(bits, @items, {0, 0}, fn bit, {weight, value}, {kg, total} ->
        {kg + bit * weight, total + bit * value}
      end)

    if weight <= 7, do: %{weight: weight, value: value}, else: {:error, {:over_weight, weight}}
  end
end
