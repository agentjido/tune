defmodule Tune.Examples.PairedReleaseTest do
  use ExUnit.Case, async: true

  @moduletag :example

  alias Tune.Examples.ReleaseGate

  test "reject a critical regression despite an improved mean and compare the same ordered cases" do
    assert {:ok, %{decision: :hold_critical_regression, comparison: paired}} = ReleaseGate.run()
    ids = ["critical", "standard", "overflow"]
    assert paired.case_ids == ids
    assert Enum.map(paired.baseline.observations, & &1.id) == ids
    assert Enum.map(paired.challenger.observations, & &1.id) == ids
    assert paired.metrics.route.delta > 0
    assert paired.metrics.route.paired_count == 3
    assert paired.rows["critical"].metrics.route.status == :regressed
  end

  test "hold when a critical score fails even if the other cases improve" do
    for failing_policy <- [:baseline, :challenger] do
      runner = fn
        %{policy: ^failing_policy}, :critical -> {:error, :unavailable}
        config, row -> ReleaseGate.route(config, row)
      end

      assert {:ok, %{decision: :hold_missing_critical_evidence, comparison: paired}} =
               ReleaseGate.run(runner: runner)

      assert paired.complete?
      assert paired.metrics.route.delta == 1.0
      assert paired.metrics.route.paired_count == 2
      assert paired.rows["critical"].metrics.route.status == :error
    end
  end

  test "require the critical row even when every supplied case has paired scores" do
    [_critical | holdout] = ReleaseGate.holdout()

    assert {:ok, %{decision: :hold_missing_critical_evidence, comparison: paired}} =
             ReleaseGate.run(holdout: holdout)

    assert paired.metrics.route.paired_count == length(paired.case_ids)
  end

  test "promote a winner that improves the mean and keeps the critical route correct" do
    runner = fn
      %{policy: :challenger}, :critical -> "risk-review"
      config, row -> ReleaseGate.route(config, row)
    end

    assert {:ok, %{decision: :promote, comparison: paired}} = ReleaseGate.run(runner: runner)
    assert paired.rows["critical"].metrics.route.status == :tied
  end

  test "duplicate IDs and expired deadlines prevent holdout evaluation" do
    target = fn _, _ -> flunk("holdout runner started") end
    [row | _] = ReleaseGate.holdout()

    assert {:error, %Tune.Error.Invalid.Definition{}} =
             ReleaseGate.run(holdout: [row, row], runner: target)

    assert {:ok, %{decision: :hold_incomplete, comparison: %{case_ids: []}}} =
             ReleaseGate.run(
               holdout: fn -> flunk("read expired data") end,
               deadline: 0,
               runner: target
             )
  end

  test "lost baseline call accounting prevents challenger execution" do
    owner = self()

    runner = fn
      %{policy: :baseline}, :standard ->
        receive do
          :release -> "billing"
        after
          2_000 -> raise "timed out without worker cleanup"
        end

      %{policy: :challenger}, row ->
        send(owner, :challenger_started)
        ReleaseGate.route(%{policy: :challenger}, row)

      config, row ->
        ReleaseGate.route(config, row)
    end

    assert {:ok, %{decision: :hold_incomplete, comparison: paired}} =
             ReleaseGate.run(runner: runner, model_calls: 5, row_calls: 1, row_timeout: 200)

    assert paired.baseline.stop_reason == :lost_accounting
    assert paired.challenger.stop_reason == :lost_accounting
    assert paired.rows["critical"].baseline.status == :ok
    refute_received :challenger_started
  end
end
