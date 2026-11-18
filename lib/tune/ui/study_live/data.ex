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
        {:noreply, assign_data(socket, study, params, "Data saved.")}
      else
        {:error, error} ->
          {:noreply, assign(socket, error: error, notice: nil, form: to_form(params, as: :data))}
      end
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.shell title={"#{@study.name}: data"} active="studies">
        <.study_steps study={@study} current={:data} />
        <div :if={@error} class="alert alert-error mb-6">{error_message(@error)}</div>
        <form phx-submit="save" class="card border border-base-300 bg-base-100">
          <div class="card-body gap-5">
          <h2 class="card-title">Edit rows</h2>
          <div class="space-y-1 text-sm">
            <p :if={@study.recipe == "saved_responses"}>
              Paste saved answers under Test rows. Use <code>input</code> with
              <code>user_input</code> and <code>retrieved_contexts</code>, and provide the saved answer as
              <code>output</code>. Use <code>expected</code> for an optional reference.
            </p>
            <p :if={@study.recipe == "structured_prompt"}>
              Paste JSON arrays with <code>inputs</code> and <code>labels</code>.
            </p>
            <p>Each split accepts up to 1,000 rows.</p>
          </div>
          <details class="collapse collapse-arrow border border-base-300 bg-base-200" open>
            <summary class="collapse-title font-medium">Test rows · {@counts.test}</summary>
            <div class="collapse-content"><textarea aria-label="Test rows" class="textarea textarea-bordered min-h-40 w-full font-mono text-sm" name="data[test]">{@form[:test].value}</textarea></div>
          </details>
          <details class="collapse collapse-arrow border border-base-300 bg-base-200">
            <summary class="collapse-title font-medium">Training rows · {@counts.train}</summary>
            <div class="collapse-content"><textarea aria-label="Training rows" class="textarea textarea-bordered min-h-40 w-full font-mono text-sm" name="data[train]">{@form[:train].value}</textarea></div>
          </details>
          <details class="collapse collapse-arrow border border-base-300 bg-base-200">
            <summary class="collapse-title font-medium">Validation rows · {@counts.validation}</summary>
            <div class="collapse-content"><textarea aria-label="Validation rows" class="textarea textarea-bordered min-h-40 w-full font-mono text-sm" name="data[validation]">{@form[:validation].value}</textarea></div>
          </details>
          <div class="card-actions items-center">
            <button class="btn btn-primary" type="submit" phx-disable-with="Saving…">Save data</button>
            <p role="status">{@notice}</p>
          </div>
          </div>
        </form>
        <section :if={@preview != []} class="card mt-6 border border-base-300 bg-base-100">
          <div class="card-body">
            <h2 class="card-title">Saved row preview</h2>
            <div class="overflow-x-auto">
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

    defp assign_data(socket, study, params, notice) do
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
        error: nil,
        notice: notice
      )
    end
  end
end
