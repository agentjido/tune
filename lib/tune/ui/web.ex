if Code.ensure_loaded?(PhoenixPlayground) do
  defmodule Tune.UI.Web do
    @moduledoc false

    defmacro __using__(:live_view) do
      quote do
        use Phoenix.LiveView
        import Tune.UI.Components
      end
    end
  end

  defmodule Tune.UI.Components do
    @moduledoc false
    use Phoenix.Component

    attr(:title, :string, required: true)
    attr(:active, :string, default: nil)
    slot(:inner_block, required: true)

    def shell(assigns) do
      ~H"""
      <link href="https://cdn.jsdelivr.net/npm/daisyui@5" rel="stylesheet" type="text/css" />
      <script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4"></script>
      <script src="https://cdn.jsdelivr.net/npm/apexcharts"></script>
      <style>
        :root {
          scrollbar-color: color-mix(in oklab, var(--color-base-content) 25%, transparent) transparent;
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
          window.dispatchEvent(new CustomEvent("tune:theme", { detail: { theme: document.documentElement.dataset.theme } }))
        }
        applyTuneColorScheme(tuneColorScheme)
        tuneColorScheme.addEventListener("change", applyTuneColorScheme)

        window.hooks.TuneChart = {
          mounted: function () {
            if (!window.ApexCharts) {
              this.el.innerHTML = '<div class="alert alert-warning">Chart assets are unavailable.</div>'
              return
            }

            var type = this.el.dataset.type || "line"
            var labels = JSON.parse(this.el.dataset.labels)
            var series = JSON.parse(this.el.dataset.series)
            var theme = document.documentElement.dataset.theme
            var styles = getComputedStyle(document.documentElement)
            var primary = styles.getPropertyValue("--color-primary").trim()
            var secondary = styles.getPropertyValue("--color-secondary").trim()
            var success = styles.getPropertyValue("--color-success").trim()
            var error = styles.getPropertyValue("--color-error").trim()
            var warning = styles.getPropertyValue("--color-warning").trim()
            var foreground = styles.getPropertyValue("--color-base-content").trim()
            var values = type === "donut" ? series : series.flatMap(function (item) { return item.data })
            var yaxis

            if (type !== "donut" && values.length > 0) {
              var minimum = Math.min.apply(null, values)
              var maximum = Math.max.apply(null, values)
              var padding = minimum === maximum ? Math.max(Math.abs(minimum) * 0.1, 0.1) : (maximum - minimum) * 0.1

              yaxis = {
                min: type === "bar" && minimum >= 0 ? 0 : minimum - padding,
                max: maximum + padding,
                decimalsInFloat: 2
              }
            }

            this.chart = new ApexCharts(this.el, {
              chart: {
                type: type === "line" ? "area" : type,
                height: Number(this.el.dataset.height || 280),
                toolbar: { show: false },
                background: "transparent",
                foreColor: foreground
              },
              series: series,
              labels: type === "donut" ? labels : undefined,
              xaxis: type === "donut" ? undefined : { categories: labels },
              yaxis: yaxis,
              colors: [primary, secondary, success, error, warning],
              dataLabels: { enabled: false },
              stroke: type === "line" ? { curve: "smooth", width: 3 } : { width: 0 },
              markers: { size: 4 },
              fill: type === "line"
                ? { type: "gradient", gradient: { opacityFrom: 0.35, opacityTo: 0.05 } }
                : { opacity: 1 },
              plotOptions: { bar: { borderRadius: 6, columnWidth: "55%" } },
              grid: { borderColor: "color-mix(in oklab, " + foreground + " 15%, transparent)" },
              theme: { mode: theme },
              legend: { position: "bottom" },
              tooltip: { theme: theme }
            })

            this.chart.render()
            this.themeHandler = function (event) {
              this.chart.updateOptions({
                theme: { mode: event.detail.theme },
                tooltip: { theme: event.detail.theme }
              })
            }.bind(this)
            window.addEventListener("tune:theme", this.themeHandler)
          },
          destroyed: function () {
            if (this.themeHandler) window.removeEventListener("tune:theme", this.themeHandler)
            if (this.chart) this.chart.destroy()
          }
        }
      </script>
      <div class="drawer min-h-screen bg-base-200 lg:drawer-open">
        <input id="tune-drawer" type="checkbox" class="drawer-toggle" />
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
                <p class="mt-1 text-sm text-base-content/60">
                  Local state only. Credentials stay in application configuration.
                </p>
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
            <ul class="menu w-full gap-1 text-base">
              <li><a class={@active == "dashboard" && "menu-active"} aria-current={if(@active == "dashboard", do: "page")} href="/">Dashboard</a></li>
              <li><a class={@active == "studies" && "menu-active"} aria-current={if(@active == "studies", do: "page")} href="/studies">Studies</a></li>
              <li><a class={@active == "new-study" && "menu-active"} aria-current={if(@active == "new-study", do: "page")} href="/studies/new">New study</a></li>
              <li><a class={@active == "artifacts" && "menu-active"} aria-current={if(@active == "artifacts", do: "page")} href="/artifacts">Artifacts</a></li>
              <li><a class={@active == "settings" && "menu-active"} aria-current={if(@active == "settings", do: "page")} href="/settings">Settings</a></li>
            </ul>
          </aside>
        </div>
      </div>
      """
    end

    attr(:study, :map, required: true)

    def study_steps(assigns) do
      ~H"""
      <nav class="tabs tabs-box mb-6 w-fit max-w-full overflow-x-auto bg-base-100">
        <a class="tab" href={"/studies/#{@study.id}"}>Overview</a>
        <a class="tab" href={"/studies/#{@study.id}/settings"}>Settings</a>
        <a class="tab" href={"/studies/#{@study.id}/data"}>Data</a>
        <a class="tab" href={"/studies/#{@study.id}/preview"}>Preview</a>
        <a class="tab" href={"/studies/#{@study.id}/run"}>Run</a>
      </nav>
      """
    end

    attr(:id, :string, required: true)
    attr(:type, :string, default: "line")
    attr(:labels, :list, required: true)
    attr(:series, :any, required: true)
    attr(:height, :integer, default: 280)
    attr(:class, :string, default: "min-h-72 w-full")

    def chart(assigns) do
      ~H"""
      <div
        id={@id}
        phx-hook="TuneChart"
        phx-update="ignore"
        data-type={@type}
        data-labels={JSON.encode!(@labels)}
        data-series={JSON.encode!(@series)}
        data-height={@height}
        class={@class}
      >
      </div>
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

  defmodule Tune.UI.Router do
    @moduledoc "The optional local workbench router."
    use Phoenix.Router
    import Phoenix.LiveView.Router

    pipeline :browser do
      plug(:accepts, ["html"])
      plug(:fetch_session)
      plug(:protect_from_forgery)
      plug(:put_root_layout, html: {PhoenixPlayground.Layout, :root})
      plug(:put_secure_browser_headers)
    end

    scope "/" do
      pipe_through(:browser)

      live("/", Tune.UI.DashboardLive)
      live("/studies", Tune.UI.StudyLive.Index)
      live("/studies/new", Tune.UI.StudyLive.New)
      live("/studies/:id", Tune.UI.StudyLive.Show)
      live("/studies/:id/settings", Tune.UI.StudyLive.Settings)
      live("/studies/:id/data", Tune.UI.StudyLive.Data)
      live("/studies/:id/preview", Tune.UI.StudyLive.Preview)
      live("/studies/:id/run", Tune.UI.StudyLive.Run)
      live("/runs/:id", Tune.UI.RunLive.Show)
      live("/artifacts", Tune.UI.ArtifactLive.Index)
      live("/settings", Tune.UI.SettingsLive)
      get("/runs/:id/artifact", Tune.UI.ArtifactController, :show)
    end
  end

  defmodule Tune.UI.DashboardLive do
    @moduledoc false
    use Tune.UI.Web, :live_view

    @impl true
    def mount(_params, _session, socket) do
      studies = Tune.UI.Store.list_studies()
      runs = Tune.UI.Store.list_runs()
      scored_runs = scored_runs(runs)

      {:ok,
       assign(socket,
         studies: studies,
         runs: runs,
         completed: Enum.count(runs, &(&1.status == :completed)),
         scored_runs: scored_runs,
         score_summary: score_summary(scored_runs),
         error: nil
       )}
    end

    @impl true
    def handle_event("load-example", _params, socket) do
      case Tune.UI.Store.create_study(Tune.UI.Examples.grounded_qa()) do
        {:ok, study} -> {:noreply, push_navigate(socket, to: "/studies/#{study.id}/preview")}
        {:error, error} -> {:noreply, assign(socket, error: error)}
      end
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.shell title="Tune dashboard" active="dashboard">
        <div :if={@error} class="alert alert-error mb-6">{error_message(@error)}</div>
        <section class="mb-6 flex flex-col gap-5 rounded-box border border-base-300 bg-base-100 p-5 shadow-sm sm:flex-row sm:items-center sm:justify-between">
          <div class="flex flex-wrap gap-x-8 gap-y-3">
            <div class="flex items-baseline gap-2">
              <span class="text-2xl font-semibold tabular-nums">{length(@studies)}</span>
              <span class="text-sm text-base-content/60">studies</span>
            </div>
            <div class="flex items-baseline gap-2">
              <span class="text-2xl font-semibold tabular-nums">{length(@runs)}</span>
              <span class="text-sm text-base-content/60">runs</span>
            </div>
            <div class="flex items-baseline gap-2">
              <span class="text-2xl font-semibold text-success tabular-nums">{@completed}</span>
              <span class="text-sm text-base-content/60">completed</span>
            </div>
          </div>
          <div class="flex flex-wrap gap-2">
            <a class="btn btn-primary" href="/studies/new">New study</a>
            <button class="btn btn-ghost" type="button" phx-click="load-example">Load example</button>
            <a class="btn btn-ghost" href="/studies">View studies</a>
          </div>
        </section>
        <div class="grid gap-6 lg:grid-cols-[minmax(0,2fr)_minmax(18rem,1fr)]">
          <section class="card border border-base-300 bg-base-100 shadow-sm">
            <div class="card-body">
              <div class="flex flex-wrap items-center justify-between gap-2">
                <div>
                  <h2 class="card-title">Score trend</h2>
                  <p class="text-sm text-base-content/60">
                    Compare runs that use the same metric and data.
                  </p>
                </div>
                <div class="badge badge-ghost">{length(@scored_runs)} scored</div>
              </div>
              <div
                :if={@score_summary}
                class="mt-4 flex flex-wrap gap-x-8 gap-y-3 border-b border-base-300 pb-4"
              >
                <div>
                  <div class="text-xs text-base-content/55">Latest</div>
                  <div class="text-lg font-semibold tabular-nums">
                    {format_score(@score_summary.latest)}
                  </div>
                </div>
                <div>
                  <div class="text-xs text-base-content/55">Best</div>
                  <div class="text-lg font-semibold tabular-nums">
                    {format_score(@score_summary.best)}
                  </div>
                </div>
                <div>
                  <div class="text-xs text-base-content/55">Change</div>
                  <div class={["text-lg font-semibold tabular-nums", change_class(@score_summary.change)]}>
                    {format_change(@score_summary.change)}
                  </div>
                </div>
              </div>
              <.chart
                :if={@scored_runs != []}
                id="run-score-chart"
                labels={Enum.map(@scored_runs, & &1.label)}
                series={[%{name: "Selected score", data: Enum.map(@scored_runs, & &1.score)}]}
                height={260}
                class="mt-2 min-h-64 w-full"
              />
              <div :if={@scored_runs == []} class="py-14 text-center text-base-content/60">
                <p>Scores appear after your first completed run.</p>
              </div>
            </div>
          </section>
          <section class="card border border-base-300 bg-base-100 shadow-sm">
            <div class="card-body">
              <h2 class="card-title">Recent runs</h2>
              <div :if={@runs == []} class="py-10 text-center text-base-content/60">
                <p>Runs will appear here.</p>
              </div>
              <div :if={@runs != []} class="divide-y divide-base-300">
                <a
                  :for={run <- Enum.take(@runs, 6)}
                  class="flex items-center justify-between gap-3 py-3 first:pt-1 last:pb-1"
                  href={"/runs/#{run.id}"}
                >
                  <div>
                    <div class="font-medium">{run.id}</div>
                    <div class="text-xs text-base-content/55">{run.mode}</div>
                  </div>
                  <div class="text-right">
                    <div :if={is_number(run_score(run.result))} class="mb-1 font-medium tabular-nums">
                      {format_score(run_score(run.result))}
                    </div>
                    <span class={["badge badge-sm", run_badge_class(run.status)]}>{run.status}</span>
                  </div>
                </a>
              </div>
            </div>
          </section>
        </div>
      </.shell>
      """
    end

    defp scored_runs(runs) do
      runs
      |> Enum.reverse()
      |> Enum.flat_map(fn run ->
        case run_score(run.result) do
          score when is_number(score) -> [%{label: run.id, score: score}]
          _other -> []
        end
      end)
    end

    defp run_score(%Tune.Evaluation{selected_score: score}), do: score
    defp run_score(%Tune.Result{best: %{evaluation: %{selected_score: score}}}), do: score
    defp run_score(_result), do: nil

    defp score_summary([]), do: nil

    defp score_summary(scored_runs) do
      first = hd(scored_runs).score
      latest = List.last(scored_runs).score

      %{
        latest: latest,
        best: scored_runs |> Enum.map(& &1.score) |> Enum.max(),
        change: if(length(scored_runs) > 1, do: latest - first)
      }
    end

    defp format_score(value) when is_float(value), do: Float.round(value, 4)
    defp format_score(value), do: value

    defp format_change(nil), do: "—"
    defp format_change(value) when value > 0, do: "+#{format_score(value)}"
    defp format_change(value), do: format_score(value)

    defp change_class(nil), do: "text-base-content/50"
    defp change_class(value) when value > 0, do: "text-success"
    defp change_class(value) when value < 0, do: "text-error"
    defp change_class(_value), do: "text-base-content"

    defp run_badge_class(:completed), do: "badge-success"
    defp run_badge_class(:failed), do: "badge-error"
    defp run_badge_class(:running), do: "badge-info"
    defp run_badge_class(_status), do: "badge-ghost"
  end

  defmodule Tune.UI.SettingsLive do
    @moduledoc false
    use Tune.UI.Web, :live_view

    @impl true
    def mount(_params, _session, socket), do: {:ok, scan(socket)}

    @impl true
    def handle_event("scan", _params, socket), do: {:noreply, scan(socket)}

    @impl true
    def render(assigns) do
      ~H"""
      <.shell title="Settings" active="settings">
        <div class="alert alert-info mb-6">
          <span>
            This scan is read-only. It combines ReqLLM diagnostics, catalog models, and
            evidence from completed workbench runs. It does not call a model or show credentials.
          </span>
        </div>

        <div class="stats stats-vertical mb-6 w-full border border-base-300 bg-base-100 shadow-sm md:stats-horizontal">
          <div class="stat">
            <div class="stat-title">ReqLLM health</div>
            <div class="stat-value text-2xl uppercase">{@health}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Configured providers</div>
            <div class="stat-value">{@configured_count}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Known models</div>
            <div class="stat-value">{@model_count}</div>
          </div>
          <div class="stat">
            <div class="stat-title">Verified by runs</div>
            <div class="stat-value text-success">{@verified_count}</div>
          </div>
        </div>

        <section class="card mb-6 border border-base-300 bg-base-100 shadow-sm">
          <div class="card-body">
            <div class="flex flex-wrap items-start justify-between gap-4">
              <div>
                <h2 class="card-title">Inference availability</h2>
                <p class="mt-1 text-sm text-base-content/60">
                  Checked {Calendar.strftime(@scanned_at, "%Y-%m-%d %H:%M:%S UTC")}.
                </p>
              </div>
              <button class="btn btn-primary" type="button" phx-click="scan">Scan again</button>
            </div>

            <div class="mt-4 overflow-x-auto">
              <table class="table">
                <thead>
                  <tr><th>Provider</th><th>Evidence</th><th>Known models</th><th>Examples</th></tr>
                </thead>
                <tbody>
                  <tr :for={provider <- @providers}>
                    <td class="font-medium">{provider.name}</td>
                    <td>
                      <span class={["badge", provider_badge_class(provider.status)]}>
                        {provider_status_label(provider.status)}
                      </span>
                    </td>
                    <td>{provider.model_count}</td>
                    <td class="max-w-xl">
                      <span :if={provider.examples == []} class="text-base-content/50">None in LLMDB</span>
                      <div :if={provider.examples != []} class="flex flex-wrap gap-1">
                        <code :for={model <- provider.examples} class="badge badge-ghost font-mono text-xs">
                          {model}
                        </code>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <div class="alert alert-warning mt-4">
              <span>
                A completed run proves that the model worked at that time. This scan does not make
                a live provider request, so it cannot prove that a server is reachable now.
              </span>
            </div>
          </div>
        </section>

        <details class="collapse collapse-arrow border border-base-300 bg-base-100 shadow-sm">
          <summary class="collapse-title text-lg font-semibold">ReqLLM diagnostics</summary>
          <div class="collapse-content">
            <div class="overflow-x-auto">
              <table class="table">
                <thead><tr><th>Check</th><th>Layer</th><th>Status</th><th>Result</th></tr></thead>
                <tbody>
                  <tr :for={check <- @checks}>
                    <td class="font-mono text-xs">{check["id"]}</td>
                    <td>{check["layer"]}</td>
                    <td>
                      <span class={["badge", check_badge_class(check["status"])]}>
                        {check["status"]}
                      </span>
                    </td>
                    <td>
                      <div>{check["message"]}</div>
                      <div :if={check["remediation"]} class="mt-1 text-sm text-base-content/60">
                        {check["remediation"]}
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </details>
      </.shell>
      """
    end

    defp scan(socket) do
      doctor = ReqLLM.Doctor.run()
      checks = doctor["checks"]
      verified = verified_models()
      models = Enum.uniq(ReqLLM.available_models() ++ verified)
      configured = check_detail(checks, "credentials.configuration", "configured_providers")

      credential_free =
        check_detail(checks, "credentials.configuration", "credential_free_providers")

      assign(socket,
        checks: checks,
        health: if(doctor["status"] == "error", do: "error", else: "ready"),
        providers: providers(models, configured, credential_free, verified),
        configured_count: length(configured),
        model_count: length(models),
        verified_count: length(verified),
        scanned_at: DateTime.utc_now()
      )
    end

    defp providers(models, configured, credential_free, verified) do
      grouped = Enum.group_by(models, &provider_name/1)
      verified_providers = MapSet.new(verified, &provider_name/1)

      (Map.keys(grouped) ++ configured ++ credential_free)
      |> Enum.uniq()
      |> Enum.map(fn name ->
        provider_models = Map.get(grouped, name, [])

        %{
          name: name,
          status: provider_status(name, configured, credential_free, verified_providers),
          model_count: length(provider_models),
          examples: Enum.take(provider_models, 4)
        }
      end)
      |> Enum.sort_by(fn provider -> {provider_status_order(provider.status), provider.name} end)
    end

    defp provider_name(model), do: model |> String.split(":", parts: 2) |> hd()

    defp provider_status(name, configured, credential_free, verified) do
      cond do
        MapSet.member?(verified, name) -> :verified
        name in configured -> :configured
        name in credential_free -> :credential_free
        true -> :catalog
      end
    end

    defp provider_status_order(:verified), do: 0
    defp provider_status_order(:configured), do: 1
    defp provider_status_order(:credential_free), do: 2
    defp provider_status_order(:catalog), do: 3

    defp provider_status_label(:verified), do: "Verified by completed run"
    defp provider_status_label(:configured), do: "Configured"
    defp provider_status_label(:credential_free), do: "No credential required"
    defp provider_status_label(:catalog), do: "Catalog"

    defp provider_badge_class(:verified), do: "badge-success"
    defp provider_badge_class(:configured), do: "badge-success"
    defp provider_badge_class(:credential_free), do: "badge-info"
    defp provider_badge_class(:catalog), do: "badge-ghost"

    defp check_badge_class("ok"), do: "badge-success"
    defp check_badge_class("warning"), do: "badge-warning"
    defp check_badge_class("error"), do: "badge-error"
    defp check_badge_class(_status), do: "badge-ghost"

    defp check_detail(checks, id, key, default \\ []) do
      checks
      |> Enum.find(%{}, &(&1["id"] == id))
      |> Map.get("details", %{})
      |> Map.get(key, default)
    end

    defp verified_models do
      studies = Map.new(Tune.UI.Store.list_studies(), &{&1.id, &1})

      Tune.UI.Store.list_runs()
      |> Enum.filter(&(&1.status == :completed))
      |> Enum.map(fn run -> get_in(studies, [run.study_id, Access.key(:config), "model"]) end)
      |> Enum.filter(&is_binary/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
    end
  end

  defmodule Tune.UI.StudyLive.Index do
    @moduledoc false
    use Tune.UI.Web, :live_view

    @impl true
    def mount(_params, _session, socket),
      do: {:ok, assign(socket, studies: Tune.UI.Store.list_studies())}

    @impl true
    def render(assigns) do
      ~H"""
      <.shell title="Studies" active="studies">
        <div class="mb-6"><a class="btn btn-primary" href="/studies/new">New study</a></div>
        <section class="card border border-base-300 bg-base-100 shadow-sm">
          <div class="card-body">
            <p :if={@studies == []} class="text-base-content/60">
              Create a study to configure data, scores, and search.
            </p>
            <div :if={@studies != []} class="overflow-x-auto">
              <table class="table">
                <thead><tr><th>Name</th><th>Recipe</th><th>Updated</th></tr></thead>
                <tbody>
                  <tr :for={study <- @studies}>
                    <td><a class="link link-primary" href={"/studies/#{study.id}"}>{study.name}</a></td>
                    <td><span class="badge badge-outline">{study.recipe}</span></td>
                    <td>{Calendar.strftime(study.updated_at, "%Y-%m-%d %H:%M")}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </section>
      </.shell>
      """
    end
  end

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
           {:ok, strategy_options} <- json_object(params["strategy_options"], "strategy options"),
           {:ok, limits} <- json_object(params["limits"], "limits"),
           config <-
             recipe.default_config()
             |> Map.merge(Map.take(params, config_keys()))
             |> Map.put("strategy_options", strategy_options)
             |> Map.put("limits", limits),
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

    defp config_keys,
      do:
        ~w(instructions input_name output_name output_type model teacher_model proposal_model adapter strategy)

    defp json_object(value, label) do
      case JSON.decode(value || "{}") do
        {:ok, object} when is_map(object) ->
          {:ok, object}

        {:ok, _other} ->
          {:error,
           Tune.Error.Invalid.Definition.exception(message: "#{label} must be a JSON object")}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defmodule Tune.UI.StudyLive.Show do
    @moduledoc false
    use Tune.UI.Web, :live_view

    @impl true
    def mount(%{"id" => id}, _session, socket) do
      case Tune.UI.Store.get_study(id) do
        nil -> {:ok, push_navigate(socket, to: "/studies")}
        study -> {:ok, assign(socket, study: study)}
      end
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.shell title={@study.name} active="studies">
        <.study_steps study={@study} />
        <div class="mb-6 grid gap-4 md:grid-cols-3">
          <section class="card border border-base-300 bg-base-100 shadow-sm">
            <div class="card-body"><div class="text-sm text-base-content/60">Recipe</div><div class="font-semibold">{@study.recipe}</div></div>
          </section>
          <section class="card border border-base-300 bg-base-100 shadow-sm">
            <div class="card-body"><div class="text-sm text-base-content/60">Strategy</div><div class="font-semibold">{@study.config["strategy"]}</div></div>
          </section>
          <section class="card border border-base-300 bg-base-100 shadow-sm">
            <div class="card-body"><div class="text-sm text-base-content/60">Model</div><div class="break-all font-semibold">{@study.config["model"]}</div></div>
          </section>
        </div>
        <section class="card border border-base-300 bg-base-100 shadow-sm">
          <div class="card-body">
            <h2 class="card-title">Configuration</h2>
            <div class="mockup-code text-sm"><pre class="px-5"><code>{Tune.JSON.pretty_encode!(@study.config)}</code></pre></div>
          </div>
        </section>
      </.shell>
      """
    end
  end

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
             error: nil
           )}
      end
    end

    @impl true
    def handle_event("save", %{"study" => params}, socket) do
      with {:ok, strategy_options} <- json_object(params["strategy_options"], "strategy options"),
           {:ok, limits} <- json_object(params["limits"], "limits"),
           config <-
             socket.assigns.study.config
             |> Map.merge(Map.take(params, config_keys()))
             |> Map.put("strategy_options", strategy_options)
             |> Map.put("limits", limits),
           {:ok, study} <-
             Tune.UI.Store.update_study(socket.assigns.study.id, %{
               name: params["name"],
               config: config
             }) do
        form =
          params
          |> Map.put("strategy_options", Tune.JSON.pretty_encode!(strategy_options))
          |> Map.put("limits", Tune.JSON.pretty_encode!(limits))
          |> to_form(as: :study)

        {:noreply, assign(socket, study: study, form: form, error: nil)}
      else
        {:error, error} ->
          {:noreply, assign(socket, error: error, form: to_form(params, as: :study))}
      end
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.shell title={"#{@study.name}: settings"} active="studies">
        <.study_steps study={@study} />
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
          <div class="card-actions justify-end"><button class="btn btn-primary" type="submit">Save settings</button></div>
          </div>
        </form>
      </.shell>
      """
    end

    defp config_keys,
      do:
        ~w(instructions input_name output_name output_type model teacher_model proposal_model adapter strategy)

    defp json_object(value, label) do
      case JSON.decode(value || "{}") do
        {:ok, object} when is_map(object) ->
          {:ok, object}

        {:ok, _other} ->
          {:error,
           Tune.Error.Invalid.Definition.exception(message: "#{label} must be a JSON object")}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defmodule Tune.UI.StudyLive.Data do
    @moduledoc false
    use Tune.UI.Web, :live_view

    @max_rows 1_000

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
      with {:ok, train} <- rows(params["train"], :train),
           {:ok, validation} <- rows(params["validation"], :validation),
           {:ok, test} <- rows(params["test"], :test),
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
            <span>Paste JSON arrays with <code>inputs</code> and <code>labels</code>. Each role accepts at most 1,000 rows.</span>
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

    defp rows(text, role) do
      with {:ok, value} <- JSON.decode(text || "[]"),
           true <- is_list(value),
           true <- length(value) <= @max_rows,
           true <- Enum.all?(value, &is_map/1) do
        {:ok, value}
      else
        false ->
          {:error,
           Tune.Error.Invalid.Definition.exception(
             message: "#{role} data must be an array of at most #{@max_rows} objects"
           )}

        {:error, error} ->
          {:error, error}
      end
    end

    defp encode(rows), do: Tune.JSON.pretty_encode!(rows)

    defp assign_data(socket, study, params, error) do
      counts = Map.new([:train, :validation, :test], &{&1, length(study.data[&1] || [])})

      preview =
        [:train, :validation, :test]
        |> Enum.flat_map(fn role ->
          study.data
          |> Map.get(role, [])
          |> Enum.map(fn row ->
            %{
              role: role,
              inputs: Map.get(row, "inputs", Map.get(row, :inputs, %{})),
              labels: Map.get(row, "labels", Map.get(row, :labels, %{}))
            }
          end)
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
        <.study_steps study={@study} />
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
    def handle_event("start", %{"mode" => mode}, socket) do
      mode = if mode == "evaluate", do: :evaluate, else: :tune

      case Tune.UI.Runner.start(socket.assigns.study, mode) do
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
            <div :if={!@preflight.tune_ready?} class="alert alert-warning mt-4">
              {@preflight.tune_issue}
            </div>
          </div>
        </section>
        <div class="grid gap-4 md:grid-cols-2">
          <section class="card border border-base-300 bg-base-100 shadow-sm">
            <div class="card-body">
            <h2 class="card-title">Evaluate</h2>
            <p class="text-base-content/70">Run the target on test, validation, or training data without search.</p>
            <div class="card-actions mt-4"><button class="btn btn-outline" disabled={!@preflight.evaluate_ready?} phx-click="start" phx-value-mode="evaluate">Start evaluation</button></div>
            </div>
          </section>
          <section class="card border border-primary/30 bg-primary text-primary-content shadow-sm">
            <div class="card-body">
            <h2 class="card-title">Tune</h2>
            <p class="opacity-80">Run the selected strategy and produce a learned-value artifact.</p>
            <div class="card-actions mt-4"><button class="btn" disabled={!@preflight.tune_ready?} phx-click="start" phx-value-mode="tune">Start tuning</button></div>
            </div>
          </section>
        </div>
      </.shell>
      """
    end

    defp preflight(study) do
      counts = Map.new([:train, :validation, :test], &{&1, length(study.data[&1] || [])})
      role = Enum.find([:test, :validation, :train], &(counts[&1] > 0))
      strategy = study.config["strategy"]
      training_only? = strategy in @training_only_strategies

      tune_issue =
        cond do
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
        model_calls: get_in(study.config, ["limits", "model_calls"]) || "not set",
        train: counts.train,
        validation: counts.validation,
        test: counts.test,
        evaluation_role: role,
        evaluation_rows: if(role, do: counts[role], else: 0),
        evaluate_ready?: not is_nil(role),
        tune_ready?: is_nil(tune_issue),
        tune_issue: tune_issue
      }
    end
  end

  defmodule Tune.UI.RunLive.Show do
    @moduledoc false
    use Tune.UI.Web, :live_view

    @impl true
    def mount(%{"id" => id}, _session, socket) do
      case Tune.UI.Store.get_run(id) do
        nil ->
          {:ok, push_navigate(socket, to: "/")}

        run ->
          if connected?(socket), do: Process.send_after(self(), :refresh, 250)
          {:ok, assign_run(socket, run)}
      end
    end

    @impl true
    def handle_info(:refresh, socket) do
      run = Tune.UI.Store.get_run(socket.assigns.run.id)
      if run.status in [:queued, :running], do: Process.send_after(self(), :refresh, 250)
      {:noreply, assign_run(socket, run)}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.shell title={"Run #{@run.id}"} active="studies">
        <div class="stats stats-vertical mb-6 w-full border border-base-300 bg-base-100 shadow-sm md:stats-horizontal">
          <div class="stat"><div class="stat-title">Status</div><div class="stat-value text-2xl">{@run.status}</div></div>
          <div class="stat"><div class="stat-title">Mode</div><div class="stat-value text-2xl">{@run.mode}</div></div>
          <div :if={@view && @view.score} class="stat"><div class="stat-title">Selected score</div><div class="stat-value text-2xl text-success">{@view.score}</div></div>
          <div :if={@duration} class="stat"><div class="stat-title">Duration</div><div class="stat-value text-2xl">{@duration}s</div></div>
        </div>
        <div :if={@run.error} class="alert alert-error mb-6">{error_message(@run.error)}</div>
        <section :if={@view} class="card mb-6 border border-base-300 bg-base-100 shadow-sm">
          <div class="card-body gap-6">
            <div class="flex flex-wrap items-center justify-between gap-2">
              <h2 class="card-title">Result</h2>
              <div class="flex flex-wrap gap-2">
                <span class="badge badge-ghost">{@view.calls} calls</span>
                <span class="badge badge-ghost">{@view.tokens} tokens</span>
                <span class="badge badge-ghost">{@view.stop_reason}</span>
              </div>
            </div>
            <div class="grid gap-4 md:grid-cols-2">
              <div class="rounded-box border border-base-300 p-4">
                <h3 class="font-semibold">Score</h3>
                <.chart
                  id={"#{@run.id}-score-chart"}
                  type="bar"
                  labels={@view.score_labels}
                  series={[%{name: "Score", data: @view.score_values}]}
                  height={240}
                  class="min-h-60 w-full"
                />
              </div>
              <div class="rounded-box border border-base-300 p-4">
                <h3 class="font-semibold">Rows</h3>
                <.chart
                  id={"#{@run.id}-rows-chart"}
                  type="donut"
                  labels={@view.status_labels}
                  series={@view.status_values}
                  height={240}
                  class="min-h-60 w-full"
                />
              </div>
            </div>
            <div :if={@view.improvement} class="alert alert-success">
              Best score improved by {format_number(@view.improvement)} over baseline.
            </div>
            <div :if={@view.rows != []} class="overflow-x-auto">
              <table class="table table-sm">
                <thead><tr><th>Row</th><th>Status</th><th>Score</th><th>Expected</th><th>Output</th></tr></thead>
                <tbody>
                  <tr :for={row <- @view.rows}>
                    <td>{row.id}</td>
                    <td><span class={["badge", row_badge_class(row.status)]}>{row.status}</span></td>
                    <td>{format_number(row.score)}</td>
                    <td><code class="text-xs">{inspect(row.expected, limit: 8)}</code></td>
                    <td><code class="text-xs">{inspect(row.output, limit: 8)}</code></td>
                  </tr>
                </tbody>
              </table>
            </div>
            <details class="collapse collapse-arrow border border-base-300 bg-base-200">
              <summary class="collapse-title font-medium">Raw result</summary>
              <div class="collapse-content">
                <div class="mockup-code max-h-[32rem] overflow-auto text-xs"><pre class="px-5"><code>{inspect(@run.result, pretty: true, limit: 40, printable_limit: 8_000)}</code></pre></div>
              </div>
            </details>
          </div>
        </section>
        <section :if={@run.artifact} class="card border border-base-300 bg-base-100 shadow-sm">
          <div class="card-body">
          <h2 class="card-title">Artifact</h2>
          <p class="text-base-content/70">Download the learned values and run provenance.</p>
          <div class="card-actions"><a class="btn btn-primary" href={"/runs/#{@run.id}/artifact"}>Download JSON</a></div>
          </div>
        </section>
      </.shell>
      """
    end

    defp assign_run(socket, run) do
      assign(socket, run: run, view: result_view(run.result), duration: duration(run))
    end

    defp result_view(nil), do: nil

    defp result_view(%Tune.Evaluation{} = evaluation) do
      evaluation_view(evaluation, ["Selected"], [evaluation.selected_score], nil)
    end

    defp result_view(%Tune.Result{} = result) do
      best = result.best && result.best.evaluation
      evaluation = best || result.baseline
      baseline_score = result.baseline && result.baseline.selected_score
      best_score = best && best.selected_score

      {labels, values} =
        [{"Baseline", baseline_score}, {"Best", best_score}]
        |> Enum.filter(fn {_label, value} -> is_number(value) end)
        |> Enum.unzip()

      improvement =
        if is_number(baseline_score) and is_number(best_score),
          do: best_score - baseline_score

      evaluation_view(evaluation, labels, values, improvement,
        calls: result.calls,
        usage: result.usage,
        stop_reason: result.stop_reason
      )
    end

    defp evaluation_view(evaluation, labels, values, improvement, overrides \\ []) do
      statuses = Enum.frequencies_by(evaluation.observations, & &1.status)
      {status_labels, status_values} = Enum.unzip(statuses)

      %{
        score: evaluation.selected_score,
        score_labels: labels,
        score_values: values,
        improvement: improvement,
        status_labels: Enum.map(status_labels, &to_string/1),
        status_values: status_values,
        calls: call_count(Keyword.get(overrides, :calls, evaluation.calls)),
        tokens: Keyword.get(overrides, :usage, evaluation.usage)[:total] || 0,
        stop_reason: Keyword.get(overrides, :stop_reason, evaluation.stop_reason),
        rows: Enum.map(evaluation.observations, &observation_row/1)
      }
    end

    defp observation_row(observation) do
      tune_case = observation.metadata[:case]

      %{
        id: observation.id,
        status: observation.status,
        score: observation.metadata[:selected_score] || first_score(observation.scores),
        expected: tune_case && tune_case.expected,
        output: observation.output
      }
    end

    defp first_score(scores) when map_size(scores) == 0, do: nil
    defp first_score(scores), do: scores |> Map.values() |> List.first()

    defp call_count(calls) do
      calls
      |> Map.values()
      |> Enum.filter(&is_number/1)
      |> Enum.sum()
    end

    defp duration(%{started_at: nil}), do: nil

    defp duration(run) do
      finished_at = run.finished_at || DateTime.utc_now()

      (DateTime.diff(finished_at, run.started_at, :microsecond) / 1_000_000)
      |> Float.round(2)
    end

    defp format_number(nil), do: "—"
    defp format_number(value) when is_float(value), do: Float.round(value, 4)
    defp format_number(value), do: value

    defp row_badge_class(:ok), do: "badge-success"
    defp row_badge_class(:error), do: "badge-error"
    defp row_badge_class(_status), do: "badge-warning"
  end

  defmodule Tune.UI.ArtifactLive.Index do
    @moduledoc false
    use Tune.UI.Web, :live_view

    @impl true
    def mount(_params, _session, socket) do
      runs = Tune.UI.Store.list_runs() |> Enum.filter(& &1.artifact)
      {:ok, assign(socket, runs: runs)}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.shell title="Artifacts" active="artifacts">
        <section class="card border border-base-300 bg-base-100 shadow-sm">
          <div class="card-body">
          <p :if={@runs == []} class="text-base-content/60">A completed tuning run will appear here.</p>
          <div :if={@runs != []} class="overflow-x-auto">
            <table class="table">
              <thead><tr><th>Run</th><th>Study</th><th>Created</th><th></th></tr></thead>
              <tbody>
                <tr :for={run <- @runs}>
                  <td><a class="link link-primary" href={"/runs/#{run.id}"}>{run.id}</a></td>
                  <td>{run.study_id}</td>
                  <td>{Calendar.strftime(run.inserted_at, "%Y-%m-%d %H:%M")}</td>
                  <td><a class="btn btn-sm btn-ghost" href={"/runs/#{run.id}/artifact"}>Download</a></td>
                </tr>
              </tbody>
            </table>
          </div>
          </div>
        </section>
      </.shell>
      """
    end
  end

  defmodule Tune.UI.ArtifactController do
    @moduledoc false
    use Phoenix.Controller, formats: [:html]

    def show(conn, %{"id" => id}) do
      case Tune.UI.Store.get_run(id) do
        %{artifact: %Tune.Artifact{} = artifact} ->
          {:ok, json} = Tune.Artifact.encode(artifact)

          conn
          |> put_resp_content_type("application/json")
          |> put_resp_header("content-disposition", ~s(attachment; filename="#{id}.json"))
          |> send_resp(200, json)

        _other ->
          send_resp(conn, 404, "artifact not found")
      end
    end
  end
end
