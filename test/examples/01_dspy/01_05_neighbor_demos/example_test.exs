defmodule Tune.Examples.NeighborDemosTest do
  use ExUnit.Case, async: true

  @moduletag :example

  alias Tune.Examples.NeighborDemos
  alias Tune.Examples.Support.Transport

  test "each request uses its nearest ticket and charges the teacher call" do
    run = NeighborDemos.neighbors(["it crashes when I start it", "card payment refund"])

    assert [
             ok: %{output: %{"label" => "bug"}, calls: %{teacher: 1, target: 1}},
             ok: %{output: %{"label" => "billing"}, calls: %{teacher: 1, target: 1}}
           ] = run.results

    assert [crash, payment] = Enum.map(run.teacher_requests, &Transport.last_user_text/1)
    assert crash =~ "the app crashes on start"
    assert payment =~ "refund my card payment"
  end

  test "a tie preserves pool order and a teacher can exhaust the allowance" do
    run = NeighborDemos.neighbors(["unrelated"], k: 2, model_calls: 2)
    assert [error: %{result: %{calls: %{teacher: 2}}}] = run.results
    assert [first, second] = Enum.map(run.teacher_requests, &Transport.last_user_text/1)
    assert first =~ "refund my card payment"
    assert second =~ "the app crashes on start"
  end
end
