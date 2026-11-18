if Code.ensure_loaded?(PhoenixPlayground) do
  defmodule Tune.UI.StudyLive.Run do
    @moduledoc false
    use Tune.UI.Web, :live_view

    @training_only_strategies ~w(labeled_few_shot bootstrap_few_shot knn_few_shot)

    @impl true
    def mount(%{"id" => id}, _session, socket) do
      case Tune.UI.Store.get_study(id) do
        nil -> {:ok, push_navigate(socket, to: "/studies")}
        study -> {:ok, assign(socket, study: study, preflight: preflight(study), error: nil)}
      end
    end

    @impl true
    def handle_event("start", %{"mode" => mode}, socket) when mode in ~w(evaluate tune) do
      mode = %{"evaluate" => :evaluate, "tune" => :tune}[mode]

      case Tune.UI.Runner.start(socket.assigns.study, mode) do
        {:ok, run} -> {:noreply, push_navigate(socket, to: "/runs/#{run.id}")}
        {:error, error} -> {:noreply, assign(socket, error: error)}
      end
    end

    def handle_event("compare", %{"split" => split}, socket) do
      case Tune.UI.Runner.start(socket.assigns.study, :compare, split: split) do
        {:ok, run} -> {:noreply, push_navigate(socket, to: "/runs/#{run.id}")}
        {:error, error} -> {:noreply, assign(socket, error: error)}
      end
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.shell title={"#{@study.name}: run"} active="studies">
        <.study_steps study={@study} />
        <div :if={@error} class="alert alert-error mb-6">{error_message(@error)}</div>
        <section class="card mb-6 border border-base-300 bg-base-100 shadow-sm">
          <div class="card-body">
            <div class="flex flex-wrap items-center justify-between gap-2">
              <h2 class="card-title">Ready to run</h2>
              <a class="btn btn-sm btn-ghost" href={"/studies/#{@study.id}/settings"}>Edit setup</a>
            </div>
            <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
              <div><div class="text-sm text-base-content/60">Target model</div><div class="break-all font-medium">{@preflight.model}</div></div>
              <div><div class="text-sm text-base-content/60">Adapter</div><div class="font-medium">{@preflight.adapter}</div></div>
              <div><div class="text-sm text-base-content/60">Strategy</div><div class="font-medium">{@preflight.strategy}</div></div>
              <div><div class="text-sm text-base-content/60">Model-call limit</div><div class="font-medium">{@preflight.model_calls}</div></div>
            </div>
            <div class="mt-2 flex flex-wrap gap-2">
              <span class="badge badge-ghost">train {@preflight.train}</span>
              <span class="badge badge-ghost">validation {@preflight.validation}</span>
              <span class="badge badge-ghost">test {@preflight.test}</span>
              <span :if={@preflight.evaluation_role} class="badge badge-info">
                evaluation uses {@preflight.evaluation_role} · {@preflight.evaluation_rows} rows
              </span>
            </div>
            <div :if={!@preflight.evaluate_ready?} class="alert alert-warning mt-4">
              Add test, validation, or training data before evaluation.
            </div>
            <div :if={@preflight.tune_issue} class="alert alert-warning mt-4">
              {@preflight.tune_issue}
            </div>
          </div>
        </section>
        <div class="grid gap-4 md:grid-cols-2">
          <section class="card border border-base-300 bg-base-100 shadow-sm">
            <div class="card-body">
            <h2 class="card-title">{if @preflight.replay?, do: "Evaluate saved answers", else: "Evaluate"}</h2>
            <div class="card-actions mt-4"><button class="btn btn-outline" disabled={!@preflight.evaluate_ready?} phx-click="start" phx-value-mode="evaluate">Start evaluation</button></div>
            </div>
          </section>
          <section :if={@study.recipe != "saved_responses"} class="card border border-primary/30 bg-primary text-primary-content shadow-sm">
            <div class="card-body">
            <h2 class="card-title">Tune</h2>
            <p class="opacity-80">Run the selected strategy and produce a learned-value artifact.</p>
            <div class="card-actions mt-4"><button class="btn" disabled={!@preflight.tune_ready?} phx-click="start" phx-value-mode="tune">Start tuning</button></div>
            </div>
          </section>
        </div>
        <div :if={@preflight.compare_ready?} class="mt-4">
          <.compare_form splits={@preflight.splits} />
        </div>
      </.shell>
      """
    end

    defp preflight(study) do
      counts = Map.new([:train, :validation, :test], &{&1, length(study.data[&1] || [])})
      replay? = study.recipe == "saved_responses"
      splits = Tune.UI.Runner.available_splits(study)
      role = List.first(splits)
      strategy = study.config["strategy"]
      training_only? = strategy in @training_only_strategies

      tune_issue =
        cond do
          study.recipe != "structured_prompt" ->
            nil

          counts.train == 0 ->
            "Add training data before tuning."

          not training_only? and counts.validation == 0 ->
            "Add validation data for candidate search."

          true ->
            nil
        end

      %{
        model: study.config["model"],
        adapter: study.config["adapter"],
        strategy: strategy,
        model_calls: Tune.Case.field(study.config["limits"] || %{}, :model_calls, "not set"),
        train: counts.train,
        validation: counts.validation,
        test: counts.test,
        evaluation_role: role,
        evaluation_rows: if(role, do: counts[role], else: 0),
        evaluate_ready?: not is_nil(role),
        tune_ready?: not replay? and is_nil(tune_issue),
        splits: splits,
        replay?: replay?,
        compare_ready?: not is_nil(Tune.UI.Runner.latest_search(study.id)),
        tune_issue: tune_issue
      }
    end
  end
end
