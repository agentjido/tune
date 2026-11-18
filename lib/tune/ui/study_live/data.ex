if Code.ensure_loaded?(PhoenixPlayground) do
  defmodule Tune.UI.StudyLive.Data do
    @moduledoc false
    use Tune.UI.Web, :live_view

    @impl true
    def mount(%{"id" => id}, _session, socket) do
      case Tune.UI.Store.get_study(id) do
        nil ->
          {:ok, push_navigate(socket, to: "/studies")}

        study ->
          params =
            Map.new([:train, :validation, :test], &{to_string(&1), encode(study.data[&1] || [])})

          {:ok, assign_data(socket, study, params, nil)}
      end
    end

    @impl true
    def handle_event("save", %{"data" => params}, socket) do
      with {:ok, train} <- JSON.decode(params["train"] || "[]"),
           {:ok, validation} <- JSON.decode(params["validation"] || "[]"),
           {:ok, test} <- JSON.decode(params["test"] || "[]"),
           {:ok, study} <-
             Tune.UI.Store.update_study(socket.assigns.study.id, %{
               data: %{train: train, validation: validation, test: test}
             }) do
        {:noreply, assign_data(socket, study, params, nil)}
      else
        {:error, error} ->
          {:noreply, assign(socket, error: error, form: to_form(params, as: :data))}
      end
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.shell title={"#{@study.name}: data"} active="studies">
        <.study_steps study={@study} />
        <div :if={@error} class="alert alert-error mb-6">{error_message(@error)}</div>
        <section class="card mb-6 border border-base-300 bg-base-100 shadow-sm">
          <div class="card-body">
            <div class="grid gap-4 md:grid-cols-2 md:items-center">
              <div class="stats stats-vertical border border-base-300 shadow-sm sm:stats-horizontal">
                <div class="stat"><div class="stat-title">Train</div><div class="stat-value text-2xl">{@counts.train}</div></div>
                <div class="stat"><div class="stat-title">Validation</div><div class="stat-value text-2xl">{@counts.validation}</div></div>
                <div class="stat"><div class="stat-title">Test</div><div class="stat-value text-2xl">{@counts.test}</div></div>
              </div>
              <.chart
                id="data-split-chart"
                type="bar"
                labels={["Train", "Validation", "Test"]}
                series={[%{name: "Rows", data: [@counts.train, @counts.validation, @counts.test]}]}
                height={180}
                class="min-h-44 w-full"
              />
            </div>
            <div :if={@preview != []} class="mt-4 overflow-x-auto">
              <table class="table table-sm">
                <thead><tr><th>Split</th><th>Inputs</th><th>Labels</th></tr></thead>
                <tbody>
                  <tr :for={row <- @preview}>
                    <td><span class="badge badge-ghost">{row.role}</span></td>
                    <td><code class="text-xs">{JSON.encode!(row.inputs)}</code></td>
                    <td><code class="text-xs">{JSON.encode!(row.labels)}</code></td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </section>
        <form phx-submit="save" class="card border border-base-300 bg-base-100 shadow-sm">
          <div class="card-body gap-5">
          <div class="alert alert-info">
            <span :if={@study.recipe == "saved_responses"}>
              Paste saved answers under Test rows. Use <code>input</code> with
              <code>user_input</code> and <code>retrieved_contexts</code>, and provide the saved answer as
              <code>output</code>. Use <code>expected</code> for an optional reference.
            </span>
            <span :if={@study.recipe == "structured_prompt"}>
              Paste JSON arrays with <code>inputs</code> and <code>labels</code>.
            </span>
            <span>Each role accepts at most 1,000 rows.</span>
          </div>
          <details class="collapse collapse-arrow border border-base-300 bg-base-200">
            <summary class="collapse-title font-medium">Training rows · {@counts.train}</summary>
            <div class="collapse-content"><textarea aria-label="Training rows" class="textarea textarea-bordered min-h-40 w-full font-mono text-sm" name="data[train]">{@form[:train].value}</textarea></div>
          </details>
          <details class="collapse collapse-arrow border border-base-300 bg-base-200">
            <summary class="collapse-title font-medium">Validation rows · {@counts.validation}</summary>
            <div class="collapse-content"><textarea aria-label="Validation rows" class="textarea textarea-bordered min-h-40 w-full font-mono text-sm" name="data[validation]">{@form[:validation].value}</textarea></div>
          </details>
          <details class="collapse collapse-arrow border border-base-300 bg-base-200">
            <summary class="collapse-title font-medium">Test rows · {@counts.test}</summary>
            <div class="collapse-content"><textarea aria-label="Test rows" class="textarea textarea-bordered min-h-40 w-full font-mono text-sm" name="data[test]">{@form[:test].value}</textarea></div>
          </details>
          <div class="card-actions justify-end"><button class="btn btn-primary" type="submit">Save data</button></div>
          </div>
        </form>
      </.shell>
      """
    end

    defp encode(rows) do
      rows
      |> Enum.map(fn
        %Tune.Replay{} = row -> Tune.Replay.to_map(row)
        row -> row
      end)
      |> Tune.JSON.pretty_encode!()
    end

    defp preview_row(%Tune.Replay{} = row, role),
      do: %{role: role, inputs: row.input, labels: row.output}

    defp preview_row(%{} = row, role) do
      %{
        role: role,
        inputs: Tune.Case.field(row, :inputs, row),
        labels: Tune.Case.field(row, :labels, %{})
      }
    end

    defp preview_row(row, role), do: %{role: role, inputs: row, labels: nil}

    defp assign_data(socket, study, params, error) do
      counts = Map.new([:train, :validation, :test], &{&1, length(study.data[&1] || [])})

      preview =
        [:train, :validation, :test]
        |> Enum.flat_map(fn role ->
          study.data
          |> Map.get(role, [])
          |> Enum.map(&preview_row(&1, role))
        end)
        |> Enum.take(5)

      assign(socket,
        study: study,
        form: to_form(params, as: :data),
        counts: counts,
        preview: preview,
        error: error
      )
    end
  end
end
