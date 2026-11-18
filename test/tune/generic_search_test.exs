defmodule Tune.GenericSearchTest do
  use ExUnit.Case, async: true

  alias Tune.Result
  alias Tune.Space

  test "a bounded genetic pipeline tunes a plain Elixir map" do
    pipeline =
      Tune.new(%{x: 0}, run: fn config -> %{fitness: -abs(config.x - 7)} end)
      |> Tune.data(validation: [nil])
      |> Tune.vary(x: 0..10)
      |> Tune.score(:fitness, & &1.fitness)
      |> Tune.search(:genetic,
        population_size: 20,
        generations: 2,
        mutation_rate: 0.2
      )
      |> Tune.limit(evaluations: 60, seed: 4)

    assert {:ok, %Result{} = result} = Tune.tune(pipeline)
    assert result.value == %{x: 7}
    assert result.parameters == %{x: 7}
    assert result.best.evaluation.selected_score == 0.0
    assert length(result.history) == 60
    assert result.complete?
  end

  test "failed candidates stay in history and are ineligible" do
    pipeline =
      Tune.new(%{x: 0},
        run: fn
          %{x: 2} -> raise "bad candidate"
          config -> config.x
        end
      )
      |> Tune.data(validation: [nil])
      |> Tune.vary(x: 0..3)
      |> Tune.score(:value, & &1)
      |> Tune.search(:genetic, population_size: 8, generations: 0)
      |> Tune.limit(evaluations: 8, seed: 1)

    assert {:ok, result} = Tune.tune(pipeline)
    assert Enum.any?(result.history, &(&1.parameters.x == 2 and not &1.evaluation.eligible?))
    assert result.value.x == 3
  end

  test "generic candidate search requires explicit validation data and an evaluation limit" do
    base =
      Tune.new(%{x: 0}, run: & &1.x)
      |> Tune.vary(x: 0..2)
      |> Tune.score(:value, & &1)
      |> Tune.search(:genetic)

    assert {:error, %Tune.Error.Invalid.Option{option: :validation}} =
             base |> Tune.limit(evaluations: 5) |> Tune.tune()

    assert {:error, %Tune.Error.Invalid.Option{option: :genetic}} =
             base |> Tune.data(validation: [nil]) |> Tune.tune()
  end

  test "uses the exact starting population and emits generation snapshots" do
    owner = self()
    seeds = [[1, 0], [0, 0], [1, 1]]

    pipeline =
      Tune.new(hd(seeds), run: & &1, on_progress: &send(owner, &1))
      |> Tune.data(validation: [:trial])
      |> Tune.score(:ones, &Enum.sum/1)
      |> Tune.search(:genetic,
        initial_population: seeds,
        generations: 8,
        target_score: 2,
        candidate_concurrency: 2
      )
      |> Tune.limit(evaluations: 27, seed: 42)

    assert {:ok, result} = Tune.tune(pipeline)
    assert result.stop_reason == :target_score
    assert result.complete?
    assert result.value == [1, 1]
    assert Enum.map(result.history, & &1.value) == seeds

    assert_received %{
      event: :generation_evaluated,
      generation: 0,
      complete?: true,
      population: population
    }

    assert Enum.map(population, & &1.value) == seeds
    refute_received %{event: :generation_evaluated, generation: 1}

    assert {:ok, artifact} = Tune.dump(result)
    assert {:ok, [1, 1]} = Tune.load(artifact, [0, 0])
    assert {:error, _error} = Tune.load(artifact, "a different genome type")
  end

  test "stops before reading validation or evaluating a pre-cancelled population" do
    pipeline =
      Tune.new(%{value: 0}, run: fn _ -> flunk("ran a cancelled candidate") end)
      |> Tune.data(validation: fn -> flunk("read a cancelled study") end)
      |> Tune.vary(value: 0..3)
      |> Tune.score(:value, & &1)
      |> Tune.search(:genetic, population_size: 4, generations: 0, cancel: fn -> true end)
      |> Tune.limit(evaluations: 4)

    assert {:error, %Tune.Error.Optimization.Failed{report: report}} = Tune.tune(pipeline)
    assert report.stop_reason == :cancelled
    assert report.history == []
  end

  test "stops the initial population at the study deadline and kills its active runner" do
    owner = self()

    pipeline =
      Tune.new(%{value: 0},
        run: fn _ ->
          send(owner, {:runner, self()})
          Process.sleep(:infinity)
        end
      )
      |> Tune.data(validation: [:trial])
      |> Tune.vary(value: 0..3)
      |> Tune.score(:value, & &1)
      |> Tune.search(:genetic, population_size: 4, generations: 0)
      |> Tune.limit(evaluations: 4, deadline: 200, row_timeout: 5_000)

    assert {:error, %Tune.Error.Optimization.Failed{report: report}} = Tune.tune(pipeline)
    assert report.stop_reason == :deadline
    assert length(report.history) == 1
    assert_received {:runner, pid}
    refute Process.alive?(pid)
    refute_received {:runner, _second}
  end

  test "uses whole-genome variation and stops after the specified generations without improvement" do
    pipeline =
      Tune.new("ab", run: & &1)
      |> Tune.data(validation: [:trial])
      |> Tune.score(:length, &String.length/1)
      |> Tune.search(:genetic,
        initial_population: ["ab", "cd"],
        mutation_rate: 1,
        crossover_rate: 1,
        crossover: fn left, right, rng -> {String.first(left) <> String.last(right), rng} end,
        mutate: fn value, rng -> {String.reverse(value), rng} end,
        patience: 1,
        elitism: 0,
        generations: 3
      )
      |> Tune.limit(evaluations: 8)

    assert {:ok, result} = Tune.tune(pipeline)
    assert result.stop_reason == :patience
    assert result.value == "ab"
    offspring = Enum.filter(result.history, &(&1.lineage.kind == :offspring))
    assert length(offspring) == 2
    assert Enum.all?(offspring, &(&1.value in ["ba", "da", "bc", "dc"]))
  end

  test "built-in spaces keep sampled and changed values valid" do
    descriptors = [1..8, {:float, 0.0, 1.0}, [:a, :b, :c], {:subset, [:a, :b, :c], 1, 2}]

    Enum.each(descriptors, fn descriptor ->
      {:ok, space} = Space.new(descriptor)
      state = :rand.seed_s(:exsss, 3)
      {left, state} = Space.sample(space, state)
      {right, state} = Space.sample(space, state)
      {mutated, state} = Space.mutate(space, left, state)
      {crossed, _state} = Space.crossover(space, left, right, state)

      assert Space.valid?(space, left)
      assert Space.valid?(space, mutated)
      assert Space.valid?(space, crossed)
    end)
  end
end
