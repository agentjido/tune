defmodule Tune.Examples.LabeledRoutingTest do
  use ExUnit.Case, async: true

  @moduletag :example

  alias Tune.Examples.LabeledRouting
  alias Tune.Examples.Support.Tickets

  test "seeded sampling ignores duplicate training rows and makes no calls during search" do
    rows = Tickets.banking()
    original = LabeledRouting.labeled(seed: 5)
    duplicates = LabeledRouting.labeled(seed: 5, train: rows ++ [hd(rows)])

    assert original.winner.value.demos == duplicates.winner.value.demos
    assert length(original.winner.value.demos) == 4
    assert duplicates.winner.metadata.notes.train_duplicates_removed == 1
    assert duplicates.search_requests == []
    assert duplicates.winner.calls == %{}
    assert duplicates.holdout.baseline.summaries.route.mean == 0.0
    assert duplicates.holdout.challenger.summaries.route.mean == 1.0
  end
end
