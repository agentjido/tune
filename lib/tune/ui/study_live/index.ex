if Code.ensure_loaded?(PhoenixPlayground) do
  defmodule Tune.UI.StudyLive.Index do
    @moduledoc false
    use Tune.UI.Web, :live_view

    @impl true
    def mount(_params, _session, socket),
      do: {:ok, assign(socket, studies: Tune.UI.Store.list_studies())}

    @impl true
    def render(assigns) do
      ~H"""
      <.shell title="Studies" active="studies">
        <div class="mb-6"><a class="btn btn-primary" href="/studies/new">New study</a></div>
        <section class="card border border-base-300 bg-base-100 shadow-sm">
          <div class="card-body">
            <p :if={@studies == []} class="text-base-content/60">
              Create a study to configure data, scores, and search.
            </p>
            <div :if={@studies != []} class="overflow-x-auto">
              <table class="table">
                <thead><tr><th>Name</th><th>Recipe</th><th>Updated</th></tr></thead>
                <tbody>
                  <tr :for={study <- @studies}>
                    <td><a class="link link-primary" href={"/studies/#{study.id}"}>{study.name}</a></td>
                    <td><span class="badge badge-outline">{study.recipe}</span></td>
                    <td>{Calendar.strftime(study.updated_at, "%Y-%m-%d %H:%M")}</td>
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
