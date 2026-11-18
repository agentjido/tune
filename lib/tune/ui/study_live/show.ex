if Code.ensure_loaded?(PhoenixPlayground) do
  defmodule Tune.UI.StudyLive.Show do
    @moduledoc false
    use Tune.UI.Web, :live_view

    @impl true
    def mount(%{"id" => id}, _session, socket) do
      case Tune.UI.Store.get_study(id) do
        nil -> {:ok, push_navigate(socket, to: "/studies")}
        study -> {:ok, assign(socket, study: study)}
      end
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.shell title={@study.name} active="studies">
        <.study_steps study={@study} />
        <div class="mb-6 grid gap-4 md:grid-cols-3">
          <section class="card border border-base-300 bg-base-100 shadow-sm">
            <div class="card-body"><div class="text-sm text-base-content/60">Recipe</div><div class="font-semibold">{@study.recipe}</div></div>
          </section>
          <section class="card border border-base-300 bg-base-100 shadow-sm">
            <div class="card-body"><div class="text-sm text-base-content/60">Strategy</div><div class="font-semibold">{@study.config["strategy"]}</div></div>
          </section>
          <section class="card border border-base-300 bg-base-100 shadow-sm">
            <div class="card-body"><div class="text-sm text-base-content/60">Model</div><div class="break-all font-semibold">{@study.config["model"]}</div></div>
          </section>
        </div>
        <section class="card border border-base-300 bg-base-100 shadow-sm">
          <div class="card-body">
            <h2 class="card-title">Configuration</h2>
            <div class="mockup-code text-sm"><pre class="px-5"><code>{Tune.JSON.pretty_encode!(@study.config)}</code></pre></div>
          </div>
        </section>
      </.shell>
      """
    end
  end
end
