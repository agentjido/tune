if Code.ensure_loaded?(PhoenixPlayground) do
  defmodule Tune.UI.StudyLive.Show do
    @moduledoc false
    use Tune.UI.Web, :live_view

    @impl true
    def mount(%{"id" => id}, _session, socket) do
      case Tune.UI.Store.get_study(id) do
        nil ->
          {:ok, push_navigate(socket, to: "/studies")}

        study ->
          {:ok,
           assign(socket, study: study, has_rows?: Tune.UI.Runner.available_splits(study) != [])}
      end
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.shell title={@study.name} active="studies">
        <.study_steps study={@study} current={:overview} />
        <section class="card mb-6 border border-base-300 bg-base-100">
          <div class="card-body gap-4">
            <dl class="grid gap-4 sm:grid-cols-3">
              <div><dt class="text-sm">Recipe</dt><dd class="font-medium">{@study.recipe}</dd></div>
              <div><dt class="text-sm">Target model</dt><dd class="break-all font-medium">{@study.config["model"]}</dd></div>
              <div><dt class="text-sm">Search strategy</dt><dd class="break-all font-medium">{@study.config["strategy"]}</dd></div>
            </dl>
            <div class="card-actions">
              <a :if={!@has_rows?} class="btn btn-primary" href={"/studies/#{@study.id}/data"}>Add data</a>
              <a :if={@has_rows?} class="btn btn-primary" href={"/studies/#{@study.id}/run"}>Run study</a>
            </div>
          </div>
        </section>
        <details class="collapse collapse-arrow border border-base-300 bg-base-100">
          <summary class="collapse-title font-medium">Configuration</summary>
          <div class="collapse-content">
            <pre class="overflow-x-auto text-sm"><code>{Tune.JSON.pretty_encode!(@study.config)}</code></pre>
          </div>
        </details>
      </.shell>
      """
    end
  end
end
