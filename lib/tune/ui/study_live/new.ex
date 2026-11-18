if Code.ensure_loaded?(PhoenixPlayground) do
  defmodule Tune.UI.StudyLive.New do
    @moduledoc false
    use Tune.UI.Web, :live_view

    @impl true
    def mount(_params, _session, socket) do
      recipes = Tune.UI.Registry.all()
      recipe = hd(recipes)

      params =
        recipe.default_config()
        |> Map.merge(%{
          "name" => "New structured prompt",
          "recipe" => recipe.id(),
          "strategy_options" =>
            Tune.JSON.pretty_encode!(recipe.default_config()["strategy_options"]),
          "limits" => Tune.JSON.pretty_encode!(recipe.default_config()["limits"])
        })

      {:ok,
       assign(socket,
         form: to_form(params, as: :study),
         recipes: recipes,
         models: Tune.UI.Components.known_models(),
         error: nil
       )}
    end

    @impl true
    def handle_event("save", %{"study" => params}, socket) do
      with {:ok, recipe} <- Tune.UI.Registry.fetch(params["recipe"]),
           {:ok, config} <- study_config(recipe.default_config(), params),
           {:ok, study} <-
             Tune.UI.Store.create_study(%{
               name: params["name"],
               recipe: recipe.id(),
               config: config,
               data: %{train: [], validation: [], test: []}
             }) do
        {:noreply, push_navigate(socket, to: "/studies/#{study.id}")}
      else
        {:error, error} ->
          {:noreply, assign(socket, error: error, form: to_form(params, as: :study))}
      end
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.shell title="New study" active="new-study">
        <div :if={@error} class="alert alert-error mb-6">{error_message(@error)}</div>
        <form phx-submit="save" class="card border border-base-300 bg-base-100 shadow-sm">
          <div class="card-body gap-5">
          <label class="form-control w-full"><span class="label-text mb-2 font-medium">Name</span><input class="input input-bordered w-full" name="study[name]" value={@form[:name].value} required /></label>
          <label class="form-control w-full"><span class="label-text mb-2 font-medium">Recipe</span>
          <select class="select select-bordered w-full" name="study[recipe]">
            <option :for={recipe <- @recipes} value={recipe.id()} selected={@form[:recipe].value == recipe.id()}>{recipe.label()}</option>
          </select></label>
          <label class="form-control w-full"><span class="label-text mb-2 font-medium">Instructions</span><textarea class="textarea textarea-bordered min-h-32 w-full" name="study[instructions]">{@form[:instructions].value}</textarea></label>
          <div class="grid gap-4 md:grid-cols-3">
            <label class="form-control"><span class="label-text mb-2 font-medium">Input field</span><input class="input input-bordered w-full" name="study[input_name]" value={@form[:input_name].value} /></label>
            <label class="form-control"><span class="label-text mb-2 font-medium">Output field</span><input class="input input-bordered w-full" name="study[output_name]" value={@form[:output_name].value} /></label>
            <label class="form-control"><span class="label-text mb-2 font-medium">Output type</span>
              <select class="select select-bordered w-full" name="study[output_type]">
                <option :for={type <- ~w(string integer float boolean)} value={type} selected={@form[:output_type].value == type}>{type}</option>
              </select></label>
          </div>
          <div class="grid gap-4 md:grid-cols-3">
            <label class="form-control"><span class="label-text mb-2 font-medium">Target model</span><input class="input input-bordered w-full" list="tune-models" name="study[model]" value={@form[:model].value} /></label>
            <label class="form-control"><span class="label-text mb-2 font-medium">Teacher model</span><input class="input input-bordered w-full" list="tune-models" name="study[teacher_model]" value={@form[:teacher_model].value} /></label>
            <label class="form-control"><span class="label-text mb-2 font-medium">Proposal model</span><input class="input input-bordered w-full" list="tune-models" name="study[proposal_model]" value={@form[:proposal_model].value} /></label>
          </div>
          <datalist id="tune-models"><option :for={model <- @models} value={model}></option></datalist>
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
          <div class="card-actions justify-end"><button class="btn btn-primary" type="submit">Create study</button></div>
          </div>
        </form>
      </.shell>
      """
    end
  end
end
