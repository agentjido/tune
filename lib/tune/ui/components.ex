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

    attr(:splits, :list, required: true)

    def compare_form(assigns) do
      ~H"""
      <section class="card mb-6 border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body">
          <h2 class="card-title">Compare with baseline</h2>
          <p :if={:test not in @splits}>No test rows. Add test data or choose another available split.</p>
          <form phx-submit="compare" class="flex flex-wrap items-end gap-3">
            <label for="comparison-split" class="form-control">
              <span class="label-text mb-1">Dataset split</span>
              <select id="comparison-split" name="split" class="select select-bordered" required disabled={@splits == []}>
                <option value="" selected>Choose a split</option>
                <option :for={split <- @splits} value={split}>{split}</option>
              </select>
            </label>
            <button class="btn btn-outline" type="submit" disabled={@splits == []}>Compare with baseline</button>
          </form>
        </div>
      </section>
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
end
