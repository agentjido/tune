if Code.ensure_loaded?(PhoenixPlayground) do
  defmodule Tune.UI.StudyLive.Settings do
    @moduledoc false
    use Tune.UI.Web, :live_view

    @impl true
    def mount(%{"id" => id}, _session, socket) do
      case Tune.UI.Store.get_study(id) do
        nil ->
          {:ok, push_navigate(socket, to: "/studies")}

        study ->
          params =
            study.config
            |> Map.put("name", study.name)
            |> Map.update("strategy_options", "{}", &Tune.JSON.pretty_encode!/1)
            |> Map.update("limits", "{}", &Tune.JSON.pretty_encode!/1)

          {:ok,
           assign(socket,
             study: study,
             form: to_form(params, as: :study),
             models: Tune.UI.Components.known_models(),
             error: nil,
             notice: nil
           )}
      end
    end

    @impl true
    def handle_event("save", %{"study" => params}, socket) do
      with {:ok, config} <- study_config(socket.assigns.study.config, params),
           {:ok, study} <-
             Tune.UI.Store.update_study(socket.assigns.study.id, %{
               name: params["name"],
               config: config
             }) do
        form =
          params
          |> Map.put(
            "strategy_options",
            Tune.JSON.pretty_encode!(study.config["strategy_options"])
          )
          |> Map.put("limits", Tune.JSON.pretty_encode!(study.config["limits"]))
          |> to_form(as: :study)

        {:noreply,
         assign(socket, study: study, form: form, error: nil, notice: "Settings saved.")}
      else
        {:error, error} ->
          {:noreply, assign(socket, error: error, notice: nil, form: to_form(params, as: :study))}
      end
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.shell title={"#{@study.name}: settings"} active="studies">
        <.study_steps study={@study} current={:settings} />
        <div :if={@error} class="alert alert-error mb-6">{error_message(@error)}</div>
        <form phx-submit="save" class="card border border-base-300 bg-base-100 shadow-sm">
          <div class="card-body gap-5">
          <label class="form-control w-full"><span class="label-text mb-2 font-medium">Name</span><input class="input input-bordered w-full" name="study[name]" value={@form[:name].value} required /></label>
          <label class="form-control w-full"><span class="label-text mb-2 font-medium">Instructions</span><textarea class="textarea textarea-bordered min-h-32 w-full" name="study[instructions]">{@form[:instructions].value}</textarea></label>
          <div class="grid gap-4 md:grid-cols-3">
            <label class="form-control"><span class="label-text mb-2 font-medium">Input field</span><input class="input input-bordered w-full" name="study[input_name]" value={@form[:input_name].value} /></label>
            <label class="form-control"><span class="label-text mb-2 font-medium">Output field</span><input class="input input-bordered w-full" name="study[output_name]" value={@form[:output_name].value} /></label>
            <label class="form-control"><span class="label-text mb-2 font-medium">Output type</span>
              <select class="select select-bordered w-full" name="study[output_type]">
                <option :for={type <- ~w(string integer float boolean)} value={type} selected={@form[:output_type].value == type}>{type}</option>
              </select></label>
          </div>
          <label class="form-control"><span class="label-text mb-2 font-medium">Target model</span><input class="input input-bordered w-full" list="tune-models" name="study[model]" value={@form[:model].value} /></label>
          <datalist id="tune-models"><option :for={model <- @models} value={model}></option></datalist>
          <details class="collapse collapse-arrow border border-base-300" open={not is_nil(@error)}>
            <summary class="collapse-title font-medium">Advanced settings</summary>
            <div class="collapse-content space-y-4">
              <div class="grid gap-4 md:grid-cols-2">
            <label class="form-control"><span class="label-text mb-2 font-medium">Teacher model</span><input class="input input-bordered w-full" list="tune-models" name="study[teacher_model]" value={@form[:teacher_model].value} /></label>
            <label class="form-control"><span class="label-text mb-2 font-medium">Proposal model</span><input class="input input-bordered w-full" list="tune-models" name="study[proposal_model]" value={@form[:proposal_model].value} /></label>
              </div>
          <div class="grid gap-4 md:grid-cols-2">
            <label class="form-control"><span class="label-text mb-2 font-medium">Adapter</span>
              <select class="select select-bordered w-full" name="study[adapter]">
                <option :for={adapter <- ~w(chat json xml)} value={adapter} selected={@form[:adapter].value == adapter}>{adapter}</option>
              </select></label>
            <label class="form-control"><span class="label-text mb-2 font-medium">Search strategy</span><input class="input input-bordered w-full" name="study[strategy]" value={@form[:strategy].value} /></label>
          </div>
          <div class="grid gap-4 md:grid-cols-2">
            <label class="form-control"><span class="label-text mb-2 font-medium">Strategy options (JSON)</span><textarea class="textarea textarea-bordered min-h-36 w-full font-mono text-sm" name="study[strategy_options]">{@form[:strategy_options].value}</textarea></label>
            <label class="form-control"><span class="label-text mb-2 font-medium">Limits (JSON)</span><textarea class="textarea textarea-bordered min-h-36 w-full font-mono text-sm" name="study[limits]">{@form[:limits].value}</textarea></label>
          </div>
            </div>
          </details>
          <div class="card-actions items-center">
            <button class="btn btn-primary" type="submit" phx-disable-with="Saving…">Save settings</button>
            <p role="status">{@notice}</p>
          </div>
          </div>
        </form>
      </.shell>
      """
    end
  end
end
