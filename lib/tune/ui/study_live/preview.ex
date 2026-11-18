if Code.ensure_loaded?(PhoenixPlayground) do
  defmodule Tune.UI.StudyLive.Preview do
    @moduledoc false
    use Tune.UI.Web, :live_view

    @impl true
    def mount(%{"id" => id}, _session, socket) do
      study = Tune.UI.Store.get_study(id)
      {:ok, assign_preview(socket, study)}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.shell title={"#{@study.name}: preview"} active="studies">
        <.study_steps study={@study} current={:preview} />
        <div :if={@error} class="alert alert-error mb-6">{error_message(@error)}</div>
        <section :if={@prepared} class="card mb-6 border border-base-300 bg-base-100 shadow-sm">
          <div class="card-body gap-5">
          <h2 class="card-title">Rendered messages</h2>
          <article :for={message <- @prepared.context.messages} class="rounded-box border border-base-300 bg-base-200 p-4">
            <div class="badge badge-neutral mb-3">{message.role}</div>
            <pre class="overflow-x-auto whitespace-pre-wrap text-sm">{Enum.map_join(message.content, "", & &1.text)}</pre>
          </article>
          </div>
        </section>
        <section class="card border border-base-300 bg-base-100 shadow-sm">
          <div class="card-body">
          <h2 class="card-title">Equivalent pipeline</h2>
          <div class="mockup-code text-sm"><pre class="px-5"><code>{pipeline_text(@study)}</code></pre></div>
          </div>
        </section>
      </.shell>
      """
    end

    defp assign_preview(socket, nil), do: push_navigate(socket, to: "/studies")

    defp assign_preview(socket, study) do
      outcome =
        with {:ok, recipe} <- Tune.UI.Registry.fetch(study.recipe),
             {:ok, pipeline} <- recipe.build(study),
             {:ok, input} <- recipe.preview_input(study) do
          Tune.preview(pipeline, input)
        end

      case outcome do
        {:ok, prepared} -> assign(socket, study: study, prepared: prepared, error: nil)
        {:error, error} -> assign(socket, study: study, prepared: nil, error: error)
      end
    end

    defp pipeline_text(study) do
      """
      Tune.new(target, model: #{inspect(study.config["model"])})
      |> Tune.data(train: train, validation: validation, test: test)
      |> Tune.score(:exact_match, score, range: {0.0, 1.0})
      |> Tune.search(#{inspect(study.config["strategy"])}, ...)
      |> Tune.limit(#{inspect(study.config["limits"])})
      """
    end
  end
end
