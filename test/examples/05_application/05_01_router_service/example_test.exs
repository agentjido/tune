defmodule Tune.Examples.RouterServiceTest do
  use ExUnit.Case, async: true

  @moduletag :example

  alias Tune.Examples.RouterService
  alias Tune.Examples.Support.Policy

  test "install into fresh trusted code and reject incompatible artifacts atomically" do
    assert RouterService.run() == %{before: "general", after_install: "risk-review"}
    supervisor = start_supervised!({Task.Supervisor, []})
    {:ok, server} = start_supervised({RouterService, supervisor: supervisor})
    {:ok, winner} = Policy.optimize()
    {:ok, artifact} = Tune.dump(winner)
    assert :ok = RouterService.install(server, artifact)
    bad = %{artifact | target_fingerprint: "incompatible"}
    assert {:error, _error} = RouterService.install(server, bad)

    assert {:ok, %{output: %{"queue" => "risk-review"}}} =
             RouterService.route(server, %{risk: 0.7})
  end

  test "requests retain a program snapshot and a timeout does not block later requests" do
    owner = self()
    supervisor = start_supervised!({Task.Supervisor, []})

    execute = fn
      program, %{risk: 0.7} = input ->
        send(owner, {:snapshot, self()})

        receive do
          :continue -> RouterService.execute(program, input)
        after
          2_000 -> raise "snapshot test was not released"
        end

      program, input ->
        RouterService.execute(program, input)
    end

    server = start_supervised!({RouterService, supervisor: supervisor, execute: execute})
    {:ok, winner} = Policy.optimize()
    {:ok, artifact} = Tune.dump(winner)
    task = Task.async(fn -> RouterService.route(server, %{risk: 0.7}) end)
    assert_receive {:snapshot, worker}
    assert :ok = RouterService.install(server, artifact)
    send(worker, :continue)
    assert {:ok, %{output: %{"queue" => "general"}}} = Task.await(task)

    assert {:error, :timeout} =
             RouterService.route(server, %{risk: 0.7}, timeout: 100)

    assert_received {:snapshot, timed_out}
    refute Process.alive?(timed_out)

    assert {:ok, %{output: %{"queue" => "risk-review"}}} =
             RouterService.route(server, %{risk: 0.71})
  end
end
