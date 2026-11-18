defmodule Tune.Examples.DispatchTest do
  @moduledoc "Example tests for dispatch evolution, stopping, and worker cleanup."
  use ExUnit.Case, async: true

  @moduletag :example

  alias Tune.Examples.Dispatch

  test "records generation zero and stops after a generation without improvement" do
    owner = self()
    assert {:ok, winner} = Dispatch.run(on_progress: &send(owner, &1))
    assert winner.value == :deadline
    assert winner.stop_reason == :patience
    assert_received %{event: :generation_evaluated, generation: 0, best: %{value: :fifo}}
    assert_received %{event: :generation_evaluated, generation: 1, best: %{value: :deadline}}
    assert_received %{event: :generation_evaluated, generation: 2, complete?: true}
  end

  test "an expired deadline stops before starting a queue runner" do
    assert {:error, %Tune.Error.Optimization.Failed{report: report}} =
             Dispatch.run(deadline: 0, runner: fn _, _ -> flunk("runner started") end)

    assert report.stop_reason == :deadline
    assert report.history == []
  end

  test "cancelling an active runner retains the last completed generation winner" do
    owner = self()
    started = :atomics.new(1, [])
    cancelled = :atomics.new(1, [])

    runner = fn policy, queue ->
      if :atomics.add_get(started, 1, 1) == 5 do
        send(owner, {:blocked, self()})
        Process.sleep(:infinity)
      end

      Dispatch.simulate(policy, queue)
    end

    task =
      Task.async(fn ->
        Dispatch.run(
          runner: runner,
          cancel: fn -> :atomics.get(cancelled, 1) == 1 end,
          on_progress: &send(owner, &1)
        )
      end)

    assert_receive {:blocked, pid}, 1_000
    :atomics.put(cancelled, 1, 1)
    assert {:ok, report} = Task.await(task)
    refute report.complete?
    assert report.stop_reason == :cancelled
    assert report.value == :fifo
    assert Enum.any?(report.history, &(&1.value == :deadline and &1.evaluation.eligible?))

    assert_received %{
      event: :generation_evaluated,
      generation: 1,
      complete?: false,
      best: %{value: :fifo}
    }

    refute Process.alive?(pid)
  end
end
