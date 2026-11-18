defmodule Tune.Examples.SavedReplayTest do
  use ExUnit.Case, async: true

  @moduletag :example

  alias Tune.Examples.SavedReplay

  test "the factory opens once and reports a missing output without target calls" do
    owner = self()

    factory = fn ->
      send(owner, :opened)

      stream =
        Stream.concat(SavedReplay.rows(), [
          %{"id" => "missing", "input" => "x"},
          :lookahead,
          :past_limit
        ])

      Stream.map(stream, fn row ->
        send(owner, {:row, row})
        row
      end)
    end

    assert {:ok, report} = SavedReplay.run(factory, cases: 3)
    assert_received :opened
    refute_received :opened

    assert [
             %{id: "paris", status: :ok},
             %{id: "rome", status: :ok},
             %{id: "missing", status: :error}
           ] =
             report.observations

    refute_received {:row, :past_limit}
    assert report.calls == %{}
  end
end
