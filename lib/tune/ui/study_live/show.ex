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
          {latest, earlier} = List.pop_at(study_runs(study.id), 0)

          {:ok,
           assign(socket,
             study: study,
             recipe: recipe_label(study.recipe),
             has_rows?: Tune.UI.Runner.available_splits(study) != [],
             latest: latest,
             earlier: earlier
           )}
      end
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.shell title={@study.name} active="studies">
        <.study_steps study={@study} current={:overview} />
        <section class="card mb-6 border border-base-300 bg-base-100" aria-labelledby="study-setup">
          <div class="card-body gap-4">
            <div class="flex flex-wrap items-center justify-between gap-2">
              <h2 id="study-setup" class="card-title">Current setup</h2>
              <a class="link text-sm" href={"/studies/#{@study.id}/settings"}>Edit setup</a>
            </div>
            <dl class="grid grid-cols-2 gap-4 sm:grid-cols-4">
              <div><dt class="text-sm">Recipe</dt><dd class="font-medium">{@recipe}</dd></div>
              <div :for={{split, label} <- [train: "Training", validation: "Validation", test: "Test"]}>
                <dt class="text-sm">{label}</dt>
                <dd class="font-medium tabular-nums">{row_count(@study.data, split)}</dd>
              </div>
            </dl>
            <div class="card-actions">
              <a :if={!@has_rows?} class="btn btn-primary" href={"/studies/#{@study.id}/data"}>Add data</a>
              <a :if={@has_rows?} class="btn btn-primary" href={"/studies/#{@study.id}/run"}>
                {if @latest, do: "Set up next run", else: "Set up first run"}
              </a>
            </div>
          </div>
        </section>
        <section class="card border border-base-300 bg-base-100" aria-labelledby="study-runs">
          <div class="card-body gap-3">
            <h2 id="study-runs" class="card-title">Run history</h2>
            <p :if={!@latest} class="text-sm">No runs yet.</p>
            <.run_entry :if={@latest} run={@latest} />
            <details :if={@earlier != []} class="collapse collapse-arrow border border-base-300">
              <summary class="collapse-title font-medium">Earlier runs ({length(@earlier)})</summary>
              <ul class="collapse-content divide-y divide-base-300">
                <li :for={run <- @earlier}><.run_entry run={run} /></li>
              </ul>
            </details>
          </div>
        </section>
      </.shell>
      """
    end

    defp run_entry(assigns) do
      ~H"""
      <a class="flex flex-wrap items-center justify-between gap-2 py-3" href={"/runs/#{@run.id}"}>
        <span class="min-w-0">
          <span class="link font-medium">{mode_label(@run.mode)} · {@run.id}</span>
          <span :if={@run.evidence} class="block text-sm">
            {Enum.map_join(@run.evidence.splits, ", ", &(&1 |> to_string() |> String.capitalize()))}
          </span>
        </span>
        <span class="badge badge-outline">{String.capitalize(to_string(@run.status))}</span>
      </a>
      """
    end

    defp study_runs(id), do: Enum.filter(Tune.UI.Store.list_runs(), &(&1.study_id == id))

    defp row_count(data, split) do
      case length(Map.get(data, split, [])) do
        1 -> "1 row"
        count -> "#{count} rows"
      end
    end

    defp recipe_label(id) do
      case Tune.UI.Registry.fetch(id) do
        {:ok, recipe} -> recipe.label()
        {:error, _} -> id
      end
    end

    defp mode_label(:evaluate), do: "Evaluation"
    defp mode_label(:tune), do: "Search"
    defp mode_label(:compare), do: "Comparison"
  end
end
