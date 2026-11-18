defmodule Tune.Examples.Background do
  @moduledoc "Let the host supervise evaluation and receive progress and reports."

  def start(supervisor, opts \\ []) do
    runner = Keyword.get(opts, :runner, fn _, answer -> answer end)
    on_report = Keyword.get(opts, :on_report, fn _ -> :ok end)

    study =
      Tune.new(:ticket_router, [run: runner] ++ Keyword.take(opts, [:on_progress, :cancel]))
      |> Tune.data(test: [%{id: "quick", input: "billing"}, %{id: "followup", input: "payments"}])
      |> Tune.score(:routed, fn route -> if is_binary(route), do: 1, else: 0 end)

    Task.Supervisor.async_nolink(supervisor, fn ->
      result = Tune.evaluate(study)
      on_report.(result)
      result
    end)
  end

  def run(on_progress, on_report) do
    {:ok, supervisor} = Task.Supervisor.start_link()

    try do
      supervisor
      |> start(on_progress: on_progress, on_report: on_report)
      |> Task.await()
    after
      Supervisor.stop(supervisor)
    end
  end
end
