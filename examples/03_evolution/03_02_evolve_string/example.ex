defmodule Tune.Examples.Spelling do
  @moduledoc "Evolve a seeded word with whole-genome operators."

  @letters ~c"TUNE"

  def spelling do
    score = fn word ->
      Enum.count(Enum.zip(String.to_charlist(word), @letters), fn {a, b} -> a == b end)
    end

    Tune.new("TTTT", run: & &1)
    |> Tune.data(validation: [:spell])
    |> Tune.score(:matching_positions, score)
    |> Tune.search(:genetic,
      initial_population: ["TTTT", "UUUU", "NNNN", "EEEE", "TTTT"],
      generations: 25,
      mutation_rate: 1,
      crossover_rate: 1,
      crossover: fn left, right, rng ->
        {cut, rng} = :rand.uniform_s(3, rng)
        {String.slice(left, 0, cut) <> String.slice(right, cut, 4 - cut), rng}
      end,
      mutate: fn word, rng ->
        {position, rng} = :rand.uniform_s(4, rng)
        {letter, rng} = :rand.uniform_s(4, rng)

        {word
         |> String.to_charlist()
         |> List.replace_at(position - 1, Enum.at(@letters, letter - 1))
         |> List.to_string(), rng}
      end,
      target_score: 4
    )
    |> Tune.limit(evaluations: 130, seed: 3)
    |> Tune.tune()
  end
end
