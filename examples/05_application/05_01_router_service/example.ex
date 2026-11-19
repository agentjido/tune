defmodule Tune.Examples.RouterService do
  @moduledoc "Apply Tune artifacts to trusted code and route requests under a host supervisor."
  use GenServer

  alias Tune.Examples.Support.{Offline, Policy}

  @doc "Starts the router with the host's task supervisor and optional request executor."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def install(server, artifact), do: GenServer.call(server, {:install, artifact})

  def route(server, input, opts \\ []) do
    {program, supervisor, execute} = GenServer.call(server, :snapshot)
    task = Task.Supervisor.async_nolink(supervisor, fn -> execute.(program, input) end)

    case Task.yield(task, Keyword.get(opts, :timeout, 1_000)) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, reason}
      nil -> {:error, :timeout}
    end
  end

  @doc "Runs a policy locally with no model calls."
  def execute(program, input) do
    Tune.Runtime.run(program, input, model: Offline.model(:unused), max_model_calls: 0)
  end

  @impl true
  def init(opts) do
    supervisor = Keyword.fetch!(opts, :supervisor)
    execute = Keyword.get(opts, :execute, &execute/2)
    {:ok, {Policy.new(), supervisor, execute}}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  def handle_call({:install, artifact}, _from, {_current, supervisor, execute} = state) do
    case Tune.load(artifact, Policy.new()) do
      {:ok, program} -> {:reply, :ok, {program, supervisor, execute}}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def run do
    {:ok, supervisor} = Task.Supervisor.start_link()
    {:ok, server} = start_link(supervisor: supervisor)

    try do
      {:ok, before} = route(server, %{risk: 0.7})
      {:ok, winner} = Policy.optimize()
      {:ok, artifact} = Tune.dump(winner)
      :ok = install(server, artifact)
      {:ok, after_install} = route(server, %{risk: 0.7})
      %{before: before.output["queue"], after_install: after_install.output["queue"]}
    after
      GenServer.stop(server)
      Supervisor.stop(supervisor)
    end
  end
end
