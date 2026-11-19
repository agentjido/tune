defmodule Tune.GridSearchTest do
  use ExUnit.Case, async: true

  test "visits all 16 batch sizes once and compares the winner on fresh workloads" do
    owner = self()

    study =
      Tune.new(%{batch_size: 1},
        run: fn config, workload ->
          send(owner, {:ran, config.batch_size, workload})
          100 - abs(config.batch_size - workload)
        end
      )
      |> Tune.data(
        validation: fn ->
          send(owner, :opened_validation)

          Stream.map([7, 99, 100], fn row ->
            send(owner, {:read, row})
            row
          end)
        end,
        test: [6, 8]
      )
      |> Tune.vary(batch_size: 1..16)
      |> Tune.score(:quality, fn _case, output -> output end)
      |> Tune.search(:grid)

    assert {:ok, winner} = study |> Tune.limit(cases: 1) |> Tune.tune()
    assert winner.complete?
    assert winner.value == %{batch_size: 7}
    assert Enum.map(winner.history, & &1.parameters.batch_size) == Enum.to_list(1..16)
    assert Enum.all?(winner.history, &(&1.evaluation.stop_reason == :case_limit))
    assert Enum.all?(winner.history, &(&1.evaluation.metadata.limits.cases == 1))

    assert_received :opened_validation
    refute_received :opened_validation
    assert_received {:read, 7}
    assert_received {:read, 99}
    refute_received {:read, _}

    for batch_size <- 1..16, do: assert_received({:ran, ^batch_size, 7})
    refute_received {:ran, _, _}

    assert {:ok, comparison} = Tune.compare(study, winner, split: :test)
    assert comparison.metrics.quality.counts == %{improved: 2}
    assert comparison.metrics.quality.delta == 5.0

    assert {:ok, artifact} = Tune.dump(winner)
    assert {:ok, %{batch_size: 7}} = Tune.load(artifact, study.target)
  end

  test "limits stable combinations from an integer range and unique choices" do
    study =
      Tune.new(%{size: 1, type: :a}, run: & &1.size)
      |> Tune.data(validation: [nil])
      |> Tune.vary(type: [:a, :a, :b], size: 10..1//-2)
      |> Tune.score(:size, & &1)
      |> Tune.search(:grid)
      |> Tune.limit(evaluations: 3)

    assert {:ok, result} = Tune.tune(study)
    refute result.complete?
    assert result.stop_reason == :evaluation_limit

    assert Enum.map(result.history, & &1.parameters) == [
             %{size: 10, type: :a},
             %{size: 10, type: :b},
             %{size: 8, type: :a}
           ]
  end

  test "rejects unsupported spaces before reading validation data" do
    study =
      Tune.new(%{x: 0}, run: fn _ -> flunk("target started") end)
      |> Tune.data(validation: fn -> flunk("data factory started") end)
      |> Tune.vary(x: {:float, 0, 1})
      |> Tune.score(:quality, & &1)
      |> Tune.search(:grid)

    assert {:error, %Tune.Error.Invalid.Option{option: :grid}} = Tune.tune(study)
  end

  test "returns a case ID error before evaluating a grid with a malformed row" do
    study =
      Tune.new(%{x: 0}, run: fn _ -> flunk("target started") end)
      |> Tune.data(validation: [%{id: %{}, input: :row}])
      |> Tune.vary(x: 0..1)
      |> Tune.score(:quality, & &1)
      |> Tune.search(:grid)

    assert {:error, %Tune.Error.Invalid.Definition{message: "row 0: invalid case ID"}} =
             Tune.tune(study)
  end

  test "grid enumeration matches the reference order and exact evaluation limit" do
    for size <- [2, 4, 6], step <- [1, 2], limit <- 0..15 do
      values = size..1//-step

      expected =
        for mode <- [:fast, :slow], value <- values, do: %{mode: mode, value: value}

      study =
        Tune.new(%{mode: :fast, value: 1}, run: & &1.value)
        |> Tune.data(validation: [nil])
        |> Tune.score(:value, & &1)
        |> Tune.vary(mode: [:fast, :slow, :fast], value: values)
        |> Tune.search(:grid)
        |> Tune.limit(evaluations: limit)

      if limit == 0 do
        assert {:error,
                %Tune.Error.Optimization.Failed{
                  report: %{history: [], stop_reason: :evaluation_limit}
                }} = Tune.tune(study)
      else
        assert {:ok, result} = Tune.tune(study)
        assert Enum.map(result.history, & &1.parameters) == Enum.take(expected, limit)
        assert result.value == hd(expected)
        assert result.complete? == limit >= length(expected)
      end
    end
  end
end
