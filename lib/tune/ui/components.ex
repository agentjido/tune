if Code.ensure_loaded?(PhoenixPlayground) do
  defmodule Tune.UI.Components do
    @moduledoc false
    use Phoenix.Component

    @config_fields ~w(instructions input_name output_name output_type model teacher_model proposal_model adapter strategy)

    def study_config(base, params) do
      with {:ok, strategy_options} <- JSON.decode(params["strategy_options"] || "{}"),
           {:ok, limits} <- JSON.decode(params["limits"] || "{}") do
        config =
          base
          |> Map.merge(Map.take(params, @config_fields))
          |> Map.put("strategy_options", strategy_options)
          |> Map.put("limits", limits)

        {:ok, config}
      end
    end

    attr(:title, :string, required: true)
    attr(:active, :string, default: nil)
    slot(:inner_block, required: true)

    def shell(assigns) do
      ~H"""
      <link href="https://cdn.jsdelivr.net/npm/daisyui@5" rel="stylesheet" type="text/css" />
      <script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4"></script>
      <style>
        :root {
          scrollbar-color: color-mix(in oklab, var(--color-base-content) 25%, transparent) transparent;
        }
        #tune-drawer:focus-visible + .drawer-content label[for="tune-drawer"] {
          outline: 2px solid var(--color-primary);
          outline-offset: 3px;
        }
        .btn-primary {
          --btn-color: color-mix(in srgb, var(--color-primary) 72%, black);
          --btn-fg: white;
        }
        ::selection {
          background: color-mix(in oklab, var(--color-primary) 32%, transparent);
          color: var(--color-base-content);
        }
        :where(a, button, input, select, textarea, summary):focus-visible {
          outline: 2px solid var(--color-primary);
          outline-offset: 3px;
        }
      </style>
      <script>
        var tuneColorScheme = window.matchMedia("(prefers-color-scheme: dark)")
        var applyTuneColorScheme = function (event) {
          document.documentElement.dataset.theme = event.matches ? "dark" : "light"
        }
        applyTuneColorScheme(tuneColorScheme)
        tuneColorScheme.addEventListener("change", applyTuneColorScheme)
      </script>
      <div class="drawer min-h-screen bg-base-200 lg:drawer-open">
        <input id="tune-drawer" type="checkbox" class="drawer-toggle lg:hidden" aria-label="Toggle main navigation" aria-controls="tune-main-nav" />
        <div class="drawer-content flex min-h-screen flex-col">
          <div class="navbar border-b border-base-300 bg-base-100 lg:hidden">
            <label for="tune-drawer" class="btn btn-square btn-ghost" aria-label="Open navigation">
              <span class="text-xl">☰</span>
            </label>
            <a class="btn btn-ghost text-lg" href="/">Tune</a>
          </div>
          <main class="flex-1 p-4 md:p-8">
            <div class="mx-auto max-w-6xl">
              <header class="mb-6">
                <h1 class="text-3xl font-bold tracking-tight">{@title}</h1>
              </header>
              {render_slot(@inner_block)}
            </div>
          </main>
        </div>
        <div class="drawer-side z-20">
          <label for="tune-drawer" aria-label="Close navigation" class="drawer-overlay"></label>
          <aside class="flex min-h-full w-64 flex-col border-r border-base-300 bg-base-100 p-4">
            <a href="/" class="mb-6 px-3 py-2">
              <div class="text-2xl font-bold">Tune</div>
              <div class="text-xs uppercase tracking-widest text-base-content/50">Workbench</div>
            </a>
            <nav id="tune-main-nav" aria-label="Main navigation">
            <ul class="menu w-full gap-1 text-base">
              <li><a class={@active == "dashboard" && "menu-active"} aria-current={if(@active == "dashboard", do: "page")} href="/">Dashboard</a></li>
              <li><a class={@active == "studies" && "menu-active"} aria-current={if(@active == "studies", do: "page")} href="/studies">Studies</a></li>
              <li><a class={@active == "new-study" && "menu-active"} aria-current={if(@active == "new-study", do: "page")} href="/studies/new">New study</a></li>
              <li><a class={@active == "artifacts" && "menu-active"} aria-current={if(@active == "artifacts", do: "page")} href="/artifacts">Artifacts</a></li>
              <li><a class={@active == "settings" && "menu-active"} aria-current={if(@active == "settings", do: "page")} href="/settings">Settings</a></li>
            </ul>
            </nav>
            <p class="mt-auto px-3 pt-6 text-sm text-base-content/80">Studies and runs stay in memory until Tune stops.</p>
          </aside>
        </div>
      </div>
      """
    end

    attr(:study, :map, required: true)
    attr(:current, :atom, required: true)

    def study_steps(assigns) do
      ~H"""
      <nav aria-label="Study navigation" class="tabs tabs-box mb-6 w-fit max-w-full flex-wrap bg-base-100">
        <a
          :for={{page, label, suffix} <- [
            {:overview, "Overview", ""},
            {:settings, "Settings", "/settings"},
            {:data, "Data", "/data"},
            {:preview, "Preview", "/preview"},
            {:run, "Run", "/run"}
          ]}
          class={["tab", @current == page && "tab-active font-semibold"]}
          aria-current={if(@current == page, do: "page")}
          href={"/studies/#{@study.id}#{suffix}"}
        >{label}</a>
      </nav>
      """
    end

    def run_setup(study, mode) do
      with {:ok, recipe} <- Tune.UI.Registry.fetch(study.recipe),
           {:ok, pipeline} <- recipe.build(study) do
        %{
          models: Tune.UI.Evidence.model_configs(pipeline),
          scores: Enum.map(pipeline.scores, & &1.name),
          limit: Map.get(pipeline.limits, :model_calls),
          splits:
            if(mode == :tune, do: Tune.UI.Runner.run_splits(pipeline, :tune, nil), else: []),
          error: nil
        }
      else
        {:error, error} -> %{error: error}
      end
    end

    attr(:setup, :map, required: true)
    attr(:counts, :map, default: %{})

    def setup_details(assigns) do
      ~H"""
      <p :if={@setup.error} class="text-sm" role="alert">{error_message(@setup.error)}</p>
      <dl :if={!@setup.error} class="grid gap-3 text-sm sm:grid-cols-3">
        <div :if={map_size(@setup.models) > 0} class="min-w-0">
          <dt class="font-semibold">Models</dt>
          <dd :for={{role, model} <- Enum.sort(@setup.models)} class="break-all">{role} · {model["model"]}</dd>
        </div>
        <div>
          <dt class="font-semibold">Metrics</dt>
          <dd>{Enum.join(@setup.scores, ", ")}</dd>
        </div>
        <div :if={@setup.limit || map_size(@setup.models) > 0}>
          <dt class="font-semibold">Model-call limit</dt>
          <dd>{@setup.limit || "Not set"}</dd>
        </div>
        <div :if={@setup.splits != []} class="sm:col-span-3">
          <dt class="font-semibold">Search data</dt>
          <dd :for={split <- @setup.splits}>{split} · {Map.get(@counts, split, 0)} rows</dd>
        </div>
      </dl>
      """
    end

    def comparison_setup(nil, _study), do: nil

    def comparison_setup(source, study) do
      %{
        source_id: source.id,
        setup: run_setup(%{source.study_snapshot | data: study.data}, :compare),
        splits: Tune.UI.Runner.available_splits(study),
        counts: Map.new(study.data, fn {split, rows} -> {split, length(rows)} end)
      }
    end

    attr(:comparison, :map, required: true)

    def compare_form(assigns) do
      ~H"""
      <section class="card mb-6 border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body">
          <h2 class="card-title">Compare with baseline</h2>
          <p class="text-sm">Search run <a class="link" href={"/runs/#{@comparison.source_id}"}>{@comparison.source_id}</a></p>
          <.setup_details setup={@comparison.setup} />
          <p :if={:test not in @comparison.splits}>No test rows. Add test data or choose another available split.</p>
          <form phx-submit="compare" class="flex flex-wrap items-end gap-3">
            <label for="comparison-split" class="form-control">
              <span class="label-text mb-1">Dataset split</span>
              <select id="comparison-split" name="split" class="select select-bordered" required disabled={@comparison.splits == [] || @comparison.setup.error != nil}>
                <option value="" selected>Choose a split</option>
                <option :for={split <- @comparison.splits} value={split}>{split} · {@comparison.counts[split]} rows</option>
              </select>
            </label>
            <button class="btn btn-outline" type="submit" disabled={@comparison.splits == [] || @comparison.setup.error != nil}>Compare with baseline</button>
          </form>
        </div>
      </section>
      """
    end

    attr(:id, :string, required: true)
    attr(:labels, :list, required: true)
    attr(:values, :list, required: true)

    def chart(assigns) do
      {min, max} = Enum.min_max([0 | assigns.values])

      assigns =
        assign(assigns,
          entries: Enum.zip(assigns.labels, assigns.values),
          min: min,
          max: if(min == max, do: 1, else: max)
        )

      ~H"""
      <dl id={@id} class="mt-3 space-y-3">
        <div :for={{label, value} <- @entries}>
          <dt class="text-sm">{label}</dt>
          <dd class="flex items-center gap-3">
            <meter aria-hidden="true" min={@min} max={@max} value={value} class="w-full"></meter>
            <span class="text-sm tabular-nums">{value}</span>
          </dd>
        </div>
      </dl>
      """
    end

    def error_message(error) when is_exception(error), do: Exception.message(error)
    def error_message(error), do: inspect(error, pretty: true, limit: 20)

    def known_models do
      study_models =
        Tune.UI.Store.list_studies()
        |> Enum.map(& &1.config["model"])
        |> Enum.filter(&is_binary/1)
        |> Enum.reject(&(&1 == ""))

      Enum.uniq(ReqLLM.available_models() ++ study_models)
    end
  end
end
