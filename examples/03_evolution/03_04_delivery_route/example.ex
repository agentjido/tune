defmodule Tune.Examples.Delivery do
  @moduledoc "Minimize distance with permutation-safe operators."

  @stops %{depot: {0, 0}, a: {0, 2}, b: {2, 2}, c: {2, 0}, d: {1, 0}}
  @routes [[:a, :c, :b, :d], [:b, :a, :d, :c], [:d, :b, :a, :c], [:c, :d, :a, :b]]

  def delivery(select_parent \\ &strongest/2) do
    Tune.new(hd(@routes), run: &distance/1)
    |> Tune.data(validation: [:roundtrip])
    |> Tune.score(:distance, & &1, direction: :minimize)
    |> Tune.search(:genetic,
      initial_population: @routes,
      generations: 12,
      valid?: &(Enum.sort(&1) == [:a, :b, :c, :d]),
      select_parent: select_parent,
      crossover_rate: 1,
      mutation_rate: 1,
      crossover: fn left, right, rng ->
        {cut, rng} = :rand.uniform_s(3, rng)
        prefix = Enum.take(left, cut)
        {prefix ++ (right -- prefix), rng}
      end,
      mutate: fn route, rng ->
        {a, rng} = :rand.uniform_s(length(route), rng)
        {b, rng} = :rand.uniform_s(length(route), rng)
        first = Enum.at(route, a - 1)
        second = Enum.at(route, b - 1)
        {route |> List.replace_at(a - 1, second) |> List.replace_at(b - 1, first), rng}
      end,
      target_score: 8
    )
    |> Tune.limit(evaluations: 52, seed: 7)
    |> Tune.tune()
  end

  def strongest(candidates, rng),
    do: {Enum.max_by(candidates, & &1.evaluation.selected_score).id, rng}

  defp distance(route) do
    [:depot | route ++ [:depot]]
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.sum_by(fn [a, b] ->
      {x, y} = @stops[a]
      {u, v} = @stops[b]
      abs(x - u) + abs(y - v)
    end)
  end
end
