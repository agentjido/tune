if Code.ensure_loaded?(PhoenixPlayground) do
  defmodule Tune.UI.DashboardLive do
    @moduledoc false
    use Tune.UI.Web, :live_view

    @impl true
    def mount(_params, _session, socket) do
      studies = Tune.UI.Store.list_studies()
      runs = Tune.UI.Store.list_runs()

      {:ok,
       assign(socket,
         studies: studies,
         runs: runs,
         completed: Enum.count(runs, &(&1.status == :completed)),
         error: nil
       )}
    end

    @impl true
    def handle_event("load-example", _params, socket) do
      case Tune.UI.Store.create_study(Tune.UI.Examples.grounded_qa()) do
        {:ok, study} -> {:noreply, push_navigate(socket, to: "/studies/#{study.id}/preview")}
        {:error, error} -> {:noreply, assign(socket, error: error)}
      end
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.shell title="Tune dashboard" active="dashboard">
        <div :if={@error} class="alert alert-error mb-6">{error_message(@error)}</div>
        <section class="mb-6 flex flex-col gap-5 rounded-box border border-base-300 bg-base-100 p-5 shadow-sm sm:flex-row sm:items-center sm:justify-between">
          <div class="flex flex-wrap gap-x-8 gap-y-3">
            <div class="flex items-baseline gap-2">
              <span class="text-2xl font-semibold tabular-nums">{length(@studies)}</span>
              <span class="text-sm text-base-content/60">studies</span>
            </div>
            <div class="flex items-baseline gap-2">
              <span class="text-2xl font-semibold tabular-nums">{length(@runs)}</span>
              <span class="text-sm text-base-content/60">runs</span>
            </div>
            <div class="flex items-baseline gap-2">
              <span class="text-2xl font-semibold text-success tabular-nums">{@completed}</span>
              <span class="text-sm text-base-content/60">completed</span>
            </div>
          </div>
          <div class="flex flex-wrap gap-2">
            <a class="btn btn-primary" href="/studies/new">New study</a>
            <button class="btn btn-ghost" type="button" phx-click="load-example">Load example</button>
            <a class="btn btn-ghost" href="/studies">View studies</a>
          </div>
        </section>
          <section class="card border border-base-300 bg-base-100 shadow-sm">
            <div class="card-body">
              <h2 class="card-title">Recent runs</h2>
              <div :if={@runs == []} class="py-10 text-center text-base-content/60">
                <p>Runs will appear here.</p>
              </div>
              <div :if={@runs != []} class="divide-y divide-base-300">
                <a
                  :for={run <- Enum.take(@runs, 6)}
                  class="flex items-center justify-between gap-3 py-3 first:pt-1 last:pb-1"
                  href={"/runs/#{run.id}"}
                >
                  <div>
                    <div class="break-words font-medium">{run.study_snapshot && run.study_snapshot.name || run.id}</div>
                    <div class="text-sm text-base-content/80">{run.mode} · {run.id}</div>
                  </div>
                  <div class="text-right">
                    <div :if={is_number(run_score(run.result))} class="mb-1 font-medium tabular-nums">
                      Score {format_score(run_score(run.result))}
                    </div>
                    <span class={["badge badge-sm", run_badge_class(run.status)]}>{run.status}</span>
                  </div>
                </a>
              </div>
            </div>
          </section>
      </.shell>
      """
    end

    defp run_score(%Tune.Evaluation{selected_score: score}), do: score
    defp run_score(%Tune.Result{best: %{evaluation: %{selected_score: score}}}), do: score
    defp run_score(_result), do: nil

    defp format_score(value) when is_float(value), do: Float.round(value, 4)
    defp format_score(value), do: value

    defp run_badge_class(:completed), do: "badge-success"
    defp run_badge_class(:failed), do: "badge-error"
    defp run_badge_class(:running), do: "badge-info"
    defp run_badge_class(_status), do: "badge-ghost"
  end
end
