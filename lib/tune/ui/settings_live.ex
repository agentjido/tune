if Code.ensure_loaded?(PhoenixPlayground) do
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
      Tune.UI.Store.list_runs()
      |> Enum.flat_map(&Tune.UI.Evidence.successful_models(&1.result))
      |> Enum.map(& &1.model)
      |> Enum.uniq()
    end
  end
end
