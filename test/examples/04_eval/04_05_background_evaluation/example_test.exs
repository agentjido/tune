defmodule Tune.Examples.BackgroundEvaluationTest do
  use ExUnit.Case, async: true

  @moduletag :example

  alias Tune.Examples.Background

  test "the host receives progress and a completed report" do
    owner = self()
    assert {:ok, report} = Background.run(&send(owner, &1), &send(owner, {:report, &1}))
    assert report.summaries.routed.mean == 1.0
    assert_received %{event: :rows_evaluated, rows: [%{id: "quick"}]}
    assert_received {:report, {:ok, ^report}}
  end

  test "cancellation returns partial observations and cleans up the active worker" do
    owner = self()
    supervisor = start_supervised!({Task.Supervisor, []})
    flag = :atomics.new(1, [])

    runner = fn
      _, "billing" ->
        "billing"

      _, "payments" ->
        send(owner, {:started, self()})

        receive do
          :release -> "payments"
        after
          5_000 -> raise "cleanup did not stop the runner"
        end
    end

    task =
      Background.start(supervisor,
        runner: runner,
        cancel: fn -> :atomics.get(flag, 1) == 1 end,
        on_report: &send(owner, {:report, &1})
      )

    assert_receive {:started, runner_pid}, 1_000
    monitor = Process.monitor(runner_pid)
    :atomics.put(flag, 1, 1)
    assert {:ok, report} = Task.await(task)
    assert_received {:report, {:ok, ^report}}
    assert_receive {:DOWN, ^monitor, :process, ^runner_pid, _reason}
    assert report.stop_reason == :cancelled

    assert [
             %{id: "quick", status: :ok},
             %{id: "followup", status: :interrupted, error: %{value: :cancelled}}
           ] = report.observations

    refute Process.alive?(task.pid)
  end
end
