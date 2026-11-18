defmodule Tune.Search.SpaceTest do
  use ExUnit.Case, async: true

  alias Tune.Error
  alias Tune.Space

  test "text operations work on graphemes and preserve the alphabet and bounds" do
    assert {:ok, space} =
             Space.new({:text, alphabet: ["é", "🙂", "é"], min_length: 1, max_length: 3})

    refute Space.valid?(space, "")
    refute Space.valid?(space, "z")
    refute Space.valid?(space, :text)
    refute Space.valid?(space, "é🙂é🙂")

    for seed <- 1..32 do
      {sample, state} = Space.sample(space, random(seed))
      assert Space.valid?(space, sample)

      {short, state} = Space.mutate(space, "é", state)
      {long, state} = Space.mutate(space, "é🙂é", state)
      {child, _state} = Space.crossover(space, "é", "🙂", state)
      assert Enum.all?([short, long, child], &Space.valid?(space, &1))
    end
  end

  test "the empty text space stays empty under mutation and crossover" do
    assert {:ok, space} = Space.new({:text, max_length: 0})
    assert {"", state} = Space.sample(space, random(2))
    assert {"", state} = Space.mutate(space, "", state)
    assert {"", _state} = Space.crossover(space, "", "", state)
  end

  test "subset operations use unique members and preserve size bounds" do
    assert {:ok, variable} = Space.new({:subset, [:a, :b, :a, :c], 1, 3})
    assert {:ok, fixed} = Space.new({:subset, [:a, :b, :c], 2, 2})
    assert {:ok, default} = Space.new({:subset, [:a, :a]})
    assert Space.valid?(default, [:a])
    refute Space.valid?(variable, [])
    refute Space.valid?(variable, [:a, :a])
    refute Space.valid?(variable, [:d])
    refute Space.valid?(variable, :a)

    for seed <- 1..32 do
      {sample, state} = Space.sample(variable, random(seed))
      assert Space.valid?(variable, sample)

      {minimum, state} = Space.mutate(variable, [:a], state)
      assert length(minimum) == 2

      {maximum, state} = Space.mutate(variable, [:a, :b, :c], state)
      assert length(maximum) == 2

      {interior, state} = Space.mutate(variable, [:a, :b], state)
      {child, state} = Space.crossover(variable, [:a, :b], [:a, :c], state)
      assert Enum.all?([minimum, maximum, interior, child], &Space.valid?(variable, &1))

      {replacement, _state} = Space.mutate(fixed, [:a, :b], state)
      assert :c in replacement
      assert Space.valid?(fixed, replacement)
    end

    assert {:ok, exact} = Space.new({:subset, [:a], 1, 1})
    assert {[:a], _state} = Space.mutate(exact, [:a], random(3))
  end

  test "float spaces keep sampled and evolved values within positive log or linear bounds" do
    for descriptor <- [{:float, -2, 4}, {:log_float, 0.1, 100}] do
      assert {:ok, space} = Space.new(descriptor)
      assert {:ok, ^space} = Space.new(space)
      {sample, state} = Space.sample(space, random(5))
      {mutated, state} = Space.mutate(space, sample, state)
      {child, _state} = Space.crossover(space, sample, mutated, state)
      assert Enum.all?([sample, mutated, child], &Space.valid?(space, &1))
    end
  end

  test "rejects malformed descriptors before a search can use them" do
    for descriptor <- [
          {:text, alphabet: []},
          {:text, min_length: 3, max_length: 2},
          {:subset, [:a], 1, 2},
          {:subset, [:a, :b], 2, 1},
          {:subset, :invalid},
          {:log_float, 0, 10},
          {:float, 9, 9},
          ~D[2026-01-01],
          :unsupported
        ] do
      assert {:error, %Error.Invalid.Definition{}} = Space.new(descriptor)
    end
  end

  defp random(seed), do: :rand.seed_s(:exsss, seed)
end
