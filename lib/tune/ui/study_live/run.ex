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
      source = socket.assigns.preflight.comparison

      case Tune.UI.Runner.start(socket.assigns.study, :compare,
             split: split,
             from: source && source.source_id
           ) do
        {:ok, run} -> {:noreply, push_navigate(socket, to: "/runs/#{run.id}")}
        {:error, error} -> {:noreply, assign(socket, error: error)}
      end
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.shell title={"#{@study.name}: run"} active="studies">
        <.study_steps study={@study} current={:run} />
        <div :if={@error} class="alert alert-error mb-6">{error_message(@error)}</div>
        <section class="card mb-6 border border-base-300 bg-base-100">
          <div class="card-body gap-4">
            <div class="flex flex-wrap items-start justify-between gap-3">
              <h2 class="card-title">{if @preflight.replay?, do: "Evaluate saved answers", else: "Evaluate"}</h2>
              <a class="btn btn-ghost btn-sm" href={"/studies/#{@study.id}/settings"}>Edit setup</a>
            </div>
            <dl class="grid gap-4 sm:grid-cols-3">
              <div :if={@preflight.model} class="min-w-0">
                <dt class="text-sm">Target model</dt>
                <dd class="break-all font-medium">{@preflight.model}</dd>
              </div>
              <div>
                <dt class="text-sm">Evaluation data</dt>
                <dd class="font-medium">
                  <span :if={@preflight.evaluation_role}>{@preflight.evaluation_role} · {@preflight.evaluation_rows} rows</span>
                  <span :if={!@preflight.evaluation_role}>No rows</span>
                </dd>
              </div>
              <div :if={@preflight.model || @preflight.model_calls}>
                <dt class="text-sm">Model-call limit</dt>
                <dd class="font-medium">{@preflight.model_calls || "not set"}</dd>
              </div>
            </dl>
            <p :if={@preflight.adapter} class="text-sm">Adapter: {@preflight.adapter}</p>
            <div :if={!@preflight.evaluate_ready?} class="alert alert-warning">
              <span>Add test, validation, or training data before evaluation.</span>
              <a class="link" href={"/studies/#{@study.id}/data"}>Add rows</a>
            </div>
            <div class="card-actions">
              <button class="btn btn-primary" disabled={!@preflight.evaluate_ready?} phx-click="start" phx-value-mode="evaluate">Start evaluation</button>
            </div>
          </div>
        </section>
        <section :if={!@preflight.replay?} class="card border border-base-300 bg-base-100">
          <div class="card-body gap-3">
            <h2 class="card-title">Tune</h2>
            <.setup_details setup={@preflight.tune} counts={@preflight.counts} />
            <p :if={@preflight.strategy} class="text-sm">Search strategy: {@preflight.strategy}</p>
            <p :if={@preflight.tune_issue} class="text-sm">
              {@preflight.tune_issue}
              <a class="link" href={"/studies/#{@study.id}/data"}>Add rows</a>
            </p>
            <div class="card-actions">
              <button class="btn btn-outline" disabled={!@preflight.tune_ready? || @preflight.tune.error != nil} phx-click="start" phx-value-mode="tune">Start tuning</button>
            </div>
          </div>
        </section>
        <div :if={@preflight.comparison} class="mt-4">
          <.compare_form comparison={@preflight.comparison} />
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
        model_calls: Tune.Case.field(study.config["limits"] || %{}, :model_calls, nil),
        evaluation_role: role,
        evaluation_rows: if(role, do: counts[role], else: 0),
        evaluate_ready?: not is_nil(role),
        tune_ready?: not replay? and is_nil(tune_issue),
        counts: counts,
        tune: if(!replay?, do: run_setup(study, :tune)),
        replay?: replay?,
        comparison: comparison_setup(Tune.UI.Runner.latest_search(study.id), study),
        tune_issue: tune_issue
      }
    end
  end
end
