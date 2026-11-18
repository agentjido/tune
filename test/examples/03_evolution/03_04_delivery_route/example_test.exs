defmodule Tune.Examples.DeliveryRouteTest do
  use ExUnit.Case, async: true

  @moduletag :example

  alias Tune.Examples.Delivery

  test "a custom selector receives eligible parents and crossover preserves the route" do
    owner = self()

    choose = fn population, rng ->
      send(owner, {:eligible, Enum.all?(population, & &1.evaluation.eligible?)})
      Delivery.strongest(population, rng)
    end

    assert {:ok, report} = Delivery.delivery(choose)
    assert_received {:eligible, true}
    assert Enum.all?(report.history, &(Enum.sort(&1.value) == [:a, :b, :c, :d]))
    assert report.best.evaluation.summaries.distance.direction == :minimize
    assert report.best.evaluation.summaries.distance.mean == 8
  end
end
