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
      with {:ok, data} <- decode_splits(params),
           {:ok, study} <- Tune.UI.Store.update_study(socket.assigns.study.id, %{data: data}) do
        {:noreply, assign_data(socket, study, params, "Data saved.")}
      else
        {:error, split, message} ->
          {:noreply, save_error(socket, params, split, message)}

        {:error, error} ->
          message = error_message(error)

          split =
            Enum.find([:test, :train, :validation], &String.starts_with?(message, "#{&1} row "))

          {:noreply, save_error(socket, params, split, message)}
      end
    end

    defp decode_splits(params) do
      Enum.reduce_while([:test, :train, :validation], {:ok, %{}}, fn split, {:ok, data} ->
        case JSON.decode(params[to_string(split)] || "[]") do
          {:ok, rows} when is_list(rows) and length(rows) <= 1_000 ->
            {:cont, {:ok, Map.put(data, split, rows)}}

          {:ok, rows} when is_list(rows) ->
            {:halt, {:error, split, "Use at most 1,000 rows."}}

          {:ok, _value} ->
            {:halt, {:error, split, "Use a JSON array of rows."}}

          {:error, _error} ->
            {:halt,
             {:error, split, "This JSON is invalid. Check the brackets, quotes, and commas."}}
        end
      end)
    end

    defp save_error(socket, params, split, message) do
      assign(socket,
        error: message,
        error_split: split,
        notice: nil,
        form: to_form(params, as: :data)
      )
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.shell title={"#{@study.name}: data"} active="studies">
        <.study_steps study={@study} current={:data} />
        <div :if={@error && !@error_split} class="alert alert-error mb-6" role="alert">{@error}</div>
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
          <details :if={@example} class="collapse collapse-arrow border border-base-300">
            <summary class="collapse-title font-medium">JSON example</summary>
            <div class="collapse-content"><pre class="overflow-x-auto text-sm"><code>{@example}</code></pre></div>
          </details>
          <details
            :for={{split, label} <- [test: "Test rows", train: "Training rows", validation: "Validation rows"]}
            class="collapse collapse-arrow border border-base-300 bg-base-200"
            open={split == :test || @error_split == split}
          >
            <summary class="collapse-title font-medium">{label} · {@counts[split]}</summary>
            <div class="collapse-content">
              <p :if={@error_split == split} id={"data-#{split}-error"} role="alert" class="mb-2 font-medium">
                {@error}
              </p>
              <textarea
                aria-label={label}
                aria-invalid={if(@error_split == split, do: "true")}
                aria-describedby={if(@error_split == split, do: "data-#{split}-error")}
                class="textarea textarea-bordered min-h-40 w-full font-mono text-sm"
                name={@form[split].name}
              >{@form[split].value}</textarea>
            </div>
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

    defp example(%{recipe: "structured_prompt", config: config}) do
      output =
        case config["output_type"] do
          "integer" -> 1
          "float" -> 1.0
          "boolean" -> true
          _ -> "Example answer"
        end

      Tune.JSON.pretty_encode!([
        %{
          inputs: %{config["input_name"] => "Example input"},
          labels: %{config["output_name"] => output}
        }
      ])
    end

    defp example(%{recipe: "saved_responses"}) do
      Tune.JSON.pretty_encode!([
        %{
          input: %{
            user_input: "What is the return window?",
            retrieved_contexts: ["Returns are accepted within 30 days."]
          },
          output: "You can return the item within 30 days."
        }
      ])
    end

    defp example(_study), do: nil

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
        error_split: nil,
        example: example(study),
        notice: notice
      )
    end
  end
end
