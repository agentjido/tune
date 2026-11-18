if Code.ensure_loaded?(PhoenixPlayground) do
  defmodule Tune.UI.ArtifactLive.Index do
    @moduledoc false
    use Tune.UI.Web, :live_view

    @impl true
    def mount(_params, _session, socket) do
      runs = Tune.UI.Store.list_runs() |> Enum.filter(& &1.artifact)
      {:ok, assign(socket, runs: runs)}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.shell title="Artifacts" active="artifacts">
        <section class="card border border-base-300 bg-base-100 shadow-sm">
          <div class="card-body">
          <p :if={@runs == []} class="text-base-content/60">A completed tuning run will appear here.</p>
          <div :if={@runs != []} class="overflow-x-auto">
            <table class="table">
              <thead><tr><th>Run</th><th>Study</th><th>Created</th><th></th></tr></thead>
              <tbody>
                <tr :for={run <- @runs}>
                  <td><a class="link link-primary" href={"/runs/#{run.id}"}>{run.id}</a></td>
                  <td>{run.study_id}</td>
                  <td>{Calendar.strftime(run.inserted_at, "%Y-%m-%d %H:%M")}</td>
                  <td><a class="btn btn-sm btn-ghost" href={"/runs/#{run.id}/artifact"}>Download</a></td>
                </tr>
              </tbody>
            </table>
          </div>
          </div>
        </section>
      </.shell>
      """
    end
  end
end
