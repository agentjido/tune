if Code.ensure_loaded?(PhoenixPlayground) do
  defmodule Tune.UI.DashboardLive do
    @moduledoc false
    use Tune.UI.Web, :live_view

    @impl true
    def mount(_params, _session, socket) do
      studies = Tune.UI.Store.list_studies()
      runs = Tune.UI.Store.list_runs()
      scored_runs = scored_runs(runs)

      {:ok,
       assign(socket,
         studies: studies,
         runs: runs,
         completed: Enum.count(runs, &(&1.status == :completed)),
         scored_runs: scored_runs,
         score_summary: score_summary(scored_runs),
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
        <div class="grid gap-6 lg:grid-cols-[minmax(0,2fr)_minmax(18rem,1fr)]">
          <section class="card border border-base-300 bg-base-100 shadow-sm">
            <div class="card-body">
              <div class="flex flex-wrap items-center justify-between gap-2">
                <div>
                  <h2 class="card-title">Score trend</h2>
                  <p class="text-sm text-base-content/60">
                    Compare runs that use the same metric and data.
                  </p>
                </div>
                <div class="badge badge-ghost">{length(@scored_runs)} scored</div>
              </div>
              <div
                :if={@score_summary}
                class="mt-4 flex flex-wrap gap-x-8 gap-y-3 border-b border-base-300 pb-4"
              >
                <div>
                  <div class="text-xs text-base-content/55">Latest</div>
                  <div class="text-lg font-semibold tabular-nums">
                    {format_score(@score_summary.latest)}
                  </div>
                </div>
                <div>
                  <div class="text-xs text-base-content/55">Best</div>
                  <div class="text-lg font-semibold tabular-nums">
                    {format_score(@score_summary.best)}
                  </div>
                </div>
                <div>
                  <div class="text-xs text-base-content/55">Change</div>
                  <div class={["text-lg font-semibold tabular-nums", change_class(@score_summary.change)]}>
                    {format_change(@score_summary.change)}
                  </div>
                </div>
              </div>
              <.chart
                :if={@scored_runs != []}
                id="run-score-chart"
                labels={Enum.map(@scored_runs, & &1.label)}
                series={[%{name: "Selected score", data: Enum.map(@scored_runs, & &1.score)}]}
                height={260}
                class="mt-2 min-h-64 w-full"
              />
              <div :if={@scored_runs == []} class="py-14 text-center text-base-content/60">
                <p>Scores appear after your first completed run.</p>
              </div>
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
                    <div class="font-medium">{run.id}</div>
                    <div class="text-xs text-base-content/55">{run.mode}</div>
                  </div>
                  <div class="text-right">
                    <div :if={is_number(run_score(run.result))} class="mb-1 font-medium tabular-nums">
                      {format_score(run_score(run.result))}
                    </div>
                    <span class={["badge badge-sm", run_badge_class(run.status)]}>{run.status}</span>
                  </div>
                </a>
              </div>
            </div>
          </section>
        </div>
      </.shell>
      """
    end

    defp scored_runs(runs) do
      runs
      |> Enum.reverse()
      |> Enum.flat_map(fn run ->
        case run_score(run.result) do
          score when is_number(score) -> [%{label: run.id, score: score}]
          _other -> []
        end
      end)
    end

    defp run_score(%Tune.Evaluation{selected_score: score}), do: score
    defp run_score(%Tune.Result{best: %{evaluation: %{selected_score: score}}}), do: score
    defp run_score(_result), do: nil

    defp score_summary([]), do: nil

    defp score_summary(scored_runs) do
      first = hd(scored_runs).score
      latest = List.last(scored_runs).score

      %{
        latest: latest,
        best: scored_runs |> Enum.map(& &1.score) |> Enum.max(),
        change: if(length(scored_runs) > 1, do: latest - first)
      }
    end

    defp format_score(value) when is_float(value), do: Float.round(value, 4)
    defp format_score(value), do: value

    defp format_change(nil), do: "—"
    defp format_change(value) when value > 0, do: "+#{format_score(value)}"
    defp format_change(value), do: format_score(value)

    defp change_class(nil), do: "text-base-content/50"
    defp change_class(value) when value > 0, do: "text-success"
    defp change_class(value) when value < 0, do: "text-error"
    defp change_class(_value), do: "text-base-content"

    defp run_badge_class(:completed), do: "badge-success"
    defp run_badge_class(:failed), do: "badge-error"
    defp run_badge_class(:running), do: "badge-info"
    defp run_badge_class(_status), do: "badge-ghost"
  end
end
