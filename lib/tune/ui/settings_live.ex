if Code.ensure_loaded?(PhoenixPlayground) do
  defmodule Tune.UI.SettingsLive do
    @moduledoc false
    use Tune.UI.Web, :live_view

    @local_providers ~w(lmstudio ollama)
    @models_per_provider 8
    @capabilities [
      {"chat", "Chat", [chat: true]},
      {"tools", "Chat with tool calls", [chat: true, tools: true]},
      {"json", "Chat with native JSON", [chat: true, json_native: true]}
    ]

    @impl true
    def mount(_params, _session, socket), do: {:ok, socket |> reset_filters() |> scan()}

    @impl true
    def handle_event("scan", _params, socket), do: {:noreply, scan(socket)}

    def handle_event("filter", %{"query" => query} = params, socket) when is_binary(query) do
      provider = params["provider"] || ""
      capability = params["capability"] || ""

      {:noreply,
       socket
       |> assign(
         query: query,
         provider: provider,
         capability: capability,
         expanded: nil,
         opened: nil
       )
       |> filter_providers()}
    end

    def handle_event("clear", _params, socket) do
      {:noreply, socket |> reset_filters() |> filter_providers()}
    end

    def handle_event("show-models", %{"provider" => provider}, socket) do
      expanded = if socket.assigns.expanded == provider, do: nil, else: provider
      {:noreply, socket |> assign(expanded: expanded, opened: provider) |> filter_providers()}
    end

    defp reset_filters(socket) do
      assign(socket, query: "", provider: "", capability: "", expanded: nil, opened: nil)
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.shell title="Model scan" active="settings">
        <div class="mb-4 flex flex-wrap items-start justify-between gap-3">
          <p class="max-w-prose text-sm">
            Find a model for a Tune study using local configuration and catalog data.
            The scan makes no model calls.
          </p>
          <div class="flex flex-wrap items-center gap-2">
            <time class="text-xs tabular-nums text-base-content/80" role="status" datetime={DateTime.to_iso8601(@scanned_at)}>
              Scanned {Calendar.strftime(@scanned_at, "%H:%M:%S UTC")}
            </time>
            <button class="btn btn-sm btn-outline" type="button" phx-click="scan" phx-disable-with="Scanning…">Scan again</button>
          </div>
        </div>

        <section class="card mb-6 border border-base-300 bg-base-100">
          <div class="card-body gap-4">
            <div>
              <h2 class="card-title">Find a model</h2>
            </div>
            <form phx-change="filter" phx-submit="filter" class="grid gap-3">
              <div class="grid gap-3 sm:grid-cols-[minmax(0,2fr)_minmax(0,1fr)]">
                <label class="min-w-0">
                  <span class="mb-1 block text-sm font-medium">Find a provider or model</span>
                  <input type="search" name="query" value={@query} placeholder="e.g. lmstudio or qwen" class="input w-full" phx-debounce="200" />
                </label>
                <label>
                  <span class="mb-1 block text-sm font-medium">Provider</span>
                  <select name="provider" class="select w-full">
                    <option value="" selected={@provider == ""}>All providers</option>
                    <option :for={provider <- @providers} value={provider.name} selected={provider.name == @provider}>{provider.name}</option>
                  </select>
                </label>
              </div>
              <details id="model-capability-filters" open={@capability != ""}>
                <summary class="link text-sm">Model capabilities</summary>
                <label class="mt-2 block">
                  <span class="mb-1 block text-sm font-medium">Capability</span>
                  <select name="capability" class="select">
                    <option value="" selected={@capability == ""}>Any capability</option>
                    <option :for={{value, label, _requirements} <- @capabilities} value={value} selected={value == @capability}>{label}</option>
                  </select>
                </label>
                <p class="mt-1 text-sm text-base-content/80">Capability filters use catalog metadata. Models without metadata are shown under Any capability.</p>
              </details>
            </form>
            <div class="flex min-h-8 flex-wrap items-center justify-between gap-2">
              <p class="text-sm tabular-nums" role="status">
                {length(@filtered_providers)} of {length(@providers)} providers
                · {@matching_count} {if @matching_count == 1, do: "model", else: "models"}
              </p>
              <button :if={filters_active?(assigns)} type="button" class="btn btn-sm btn-ghost" phx-click="clear">Clear filters</button>
            </div>
            <p :if={@filtered_providers == []} class="text-sm">No providers or models match this search.</p>
            <ul :if={@filtered_providers != []} class="divide-y divide-base-300 border-y border-base-300">
              <li :for={provider <- @filtered_providers}>
                <details id={"model-provider-#{provider.name}"} class="collapse collapse-arrow" open={@open_matches? || @opened == provider.name}>
                  <summary class="collapse-title flex flex-wrap items-center gap-x-3 gap-y-1 py-3 hover:bg-base-200/60">
                    <span class="break-all font-semibold">{provider.name}</span>
                    <span class={["badge badge-sm", provider_badge_class(provider.status)]}>{provider_status_label(provider.status)}</span>
                    <span :if={provider.responded?} class="text-sm">Verified by completed run</span>
                    <span class="ml-auto text-sm tabular-nums">{provider.match_count} {if provider.match_count == 1, do: "model", else: "models"}</span>
                  </summary>
                  <div class="collapse-content">
                    <p :if={provider.models == [] && provider.status == :credential_free} class="text-sm">
                      Use the exact model ID from your local server, with the <code>{provider.name}:</code> prefix.
                    </p>
                    <p :if={provider.models == [] && provider.status != :credential_free} class="text-sm">No model IDs recorded.</p>
                    <ul :if={provider.models != []} class="divide-y divide-base-300">
                      <li :for={model <- provider.models} class="flex flex-wrap items-center justify-between gap-2 py-2">
                        <code class="min-w-0 break-all text-sm">{model}</code>
                        <a class="btn btn-sm btn-ghost" href={"/studies/new?" <> URI.encode_query(%{"model" => model})} aria-label={"Use #{model} in a new study"}>Use in study</a>
                      </li>
                    </ul>
                    <button :if={provider.match_count > length(provider.models) || @expanded == provider.name}
                      class="btn btn-ghost btn-sm mt-2" type="button" phx-click="show-models" phx-value-provider={provider.name}>
                      {if @expanded == provider.name, do: "Show fewer models", else: "Show all #{provider.match_count} models"}
                    </button>
                  </div>
                </details>
              </li>
            </ul>
          </div>
        </section>

        <details class="collapse collapse-arrow mb-3 border border-base-300 bg-base-100">
          <summary class="collapse-title font-semibold">Models that responded · {@verified_count}</summary>
          <div class="collapse-content">
            <p class="text-sm">A response confirms the model worked at the time of that run.</p>
            <p :if={@verified == []} class="mt-2 text-sm">No completed runs in this workbench have recorded a model response.</p>
            <ul :if={@verified != []} class="mt-2 divide-y divide-base-300">
              <li :for={entry <- @verified} class="flex flex-wrap items-center justify-between gap-2 py-2">
                <code class="break-all text-sm">{entry.model}</code>
                <a class="link" href={"/runs/#{entry.run_id}"}>View {entry.run_id}</a>
              </li>
            </ul>
          </div>
        </details>

        <details class="collapse collapse-arrow border border-base-300 bg-base-100">
          <summary class="collapse-title font-semibold">ReqLLM diagnostics · {check_summary(@health)}</summary>
          <div class="collapse-content space-y-3">
            <p class="text-sm" role="status">
              Last scanned <time datetime={DateTime.to_iso8601(@scanned_at)}>{Calendar.strftime(@scanned_at, "%Y-%m-%d %H:%M:%S UTC")}</time>
              · {@configured_count} configured providers · {@model_count} known models
            </p>
            <p class="text-sm">Configuration alone cannot confirm that a provider is reachable. Tune reads <code>.env</code> at startup.</p>
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
      models = Enum.uniq(ReqLLM.available_models() ++ Enum.map(verified, & &1.model))
      configured = check_detail(checks, "credentials.configuration", "configured_providers")

      credential_free =
        check_detail(
          checks,
          "credentials.configuration",
          "credential_free_providers",
          @local_providers
        )

      assign(socket,
        checks: checks,
        capabilities: @capabilities,
        capability_models:
          Map.new(@capabilities, fn {id, _label, requirements} ->
            {id, MapSet.new(ReqLLM.available_models(require: requirements))}
          end),
        health: doctor["status"],
        verified: verified,
        providers: providers(models, configured, credential_free, verified),
        configured_count: length(configured),
        model_count: length(models),
        verified_count: length(verified),
        scanned_at: DateTime.utc_now()
      )
      |> filter_providers()
    end

    defp providers(models, configured, credential_free, verified) do
      grouped = Enum.group_by(models, &provider_name/1)
      verified_providers = MapSet.new(verified, &provider_name(&1.model))

      (Map.keys(grouped) ++ configured ++ credential_free)
      |> Enum.uniq()
      |> Enum.map(fn name ->
        provider_models = Map.get(grouped, name, [])

        %{
          name: name,
          status: provider_status(name, configured, credential_free),
          responded?: MapSet.member?(verified_providers, name),
          models: Enum.sort(provider_models)
        }
      end)
      |> Enum.sort_by(fn provider ->
        {!provider.responded?, provider_status_order(provider.status), provider.name}
      end)
    end

    defp provider_name(model), do: model |> String.split(":", parts: 2) |> hd()

    defp provider_status(name, configured, credential_free) do
      cond do
        name in configured -> :configured
        name in credential_free -> :credential_free
        true -> :catalog
      end
    end

    defp provider_status_order(:configured), do: 1
    defp provider_status_order(:credential_free), do: 2
    defp provider_status_order(:catalog), do: 3

    defp provider_status_label(:configured), do: "Configured"
    defp provider_status_label(:credential_free), do: "No credential required"
    defp provider_status_label(:catalog), do: "No configuration detected"

    defp provider_badge_class(:configured), do: "badge-info"
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

    defp filters_active?(assigns) do
      assigns.query != "" || assigns.provider != "" || assigns.capability != ""
    end

    defp filter_providers(socket) do
      %{query: query, provider: selected, capability: capability, expanded: expanded} =
        socket.assigns

      query = query |> String.trim() |> String.downcase()
      allowed = socket.assigns.capability_models[capability]

      matches =
        for provider <- socket.assigns.providers, selected in ["", provider.name] do
          provider_match? = String.contains?(String.downcase(provider.name), query)

          models =
            Enum.filter(provider.models, fn model ->
              (is_nil(allowed) || MapSet.member?(allowed, model)) &&
                (provider_match? || String.contains?(String.downcase(model), query))
            end)

          Map.merge(provider, %{
            match?: models != [] || (provider_match? && is_nil(allowed)),
            models:
              if(expanded == provider.name,
                do: models,
                else: Enum.take(models, @models_per_provider)
              ),
            match_count: length(models)
          })
        end

      filtered = Enum.filter(matches, & &1.match?)

      assign(socket,
        filtered_providers: filtered,
        open_matches?: selected != "" || (query != "" && length(filtered) <= 3),
        matching_count: Enum.sum_by(filtered, & &1.match_count)
      )
    end

    defp check_summary("ok"), do: "Passed"
    defp check_summary("warning"), do: "Warnings"
    defp check_summary("error"), do: "Errors"
    defp check_summary(_status), do: "Unknown"

    defp verified_models do
      Tune.UI.Store.list_runs()
      |> Enum.filter(&(&1.status == :completed))
      |> Enum.sort_by(& &1.finished_at, {:desc, DateTime})
      |> Enum.flat_map(fn run ->
        Enum.map(
          Tune.UI.Evidence.successful_models(run.result),
          &%{model: &1.model, run_id: run.id}
        )
      end)
      |> Enum.uniq_by(& &1.model)
    end
  end
end
