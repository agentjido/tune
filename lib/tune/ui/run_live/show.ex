if Code.ensure_loaded?(PhoenixPlayground) do
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
    def handle_event("cancel", _params, socket) do
      :ok = Tune.UI.Runner.cancel(socket.assigns.run.id)
      {:noreply, assign_run(socket, Tune.UI.Store.get_run(socket.assigns.run.id))}
    end

    def handle_event("compare", %{"split" => split}, socket) do
      run = socket.assigns.run
      study = Tune.UI.Store.get_study(run.study_id)

      case Tune.UI.Runner.start(study, :compare, split: split, from: run.id) do
        {:ok, comparison} -> {:noreply, push_navigate(socket, to: "/runs/#{comparison.id}")}
        {:error, error} -> {:noreply, assign(socket, comparison_error: error)}
      end
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.shell title={"Run #{@run.id}"} active="studies">
        <div class="mb-4 flex flex-wrap gap-2">
          <a class="btn btn-ghost btn-sm" href={"/studies/#{@run.study_id}"}>Study overview</a>
          <a class="btn btn-outline btn-sm" href={"/studies/#{@run.study_id}/run"}>Run setup</a>
        </div>
        <div class="stats stats-vertical mb-6 w-full border border-base-300 bg-base-100 shadow-sm md:stats-horizontal">
          <div class="stat"><div class="stat-title">Status</div><div class="stat-value text-2xl" role="status">{@run.status}</div></div>
          <div class="stat"><div class="stat-title">Mode</div><div class="stat-value text-2xl">{@run.mode}</div></div>
          <div :if={@view && @view.score} class="stat"><div class="stat-title">Selected score</div><div class="stat-value text-2xl text-success">{@view.score}</div></div>
          <div :if={@duration} class="stat"><div class="stat-title">Duration</div><div class="stat-value text-2xl">{@duration}s</div></div>
        </div>
        <div class="mb-4 flex flex-wrap items-center gap-3">
          <div role="status" class="flex flex-wrap gap-3">
          <span>Rows: {@run.progress.rows}</span>
          <span :if={@run.mode == :tune}>Candidates: {@run.progress.candidates}</span>
          <span :if={@run.mode == :tune}>Generations: {@run.progress.generations}</span>
          </div>
          <button :if={@run.status in [:queued, :running]} class="btn btn-sm btn-outline"
            disabled={@run.cancel_requested?} phx-click="cancel" phx-disable-with="Cancelling…">{if @run.cancel_requested?, do: "Cancelling…", else: "Cancel"}</button>
        </div>
        <div :if={@run.error} class="alert alert-error mb-6">{error_message(@run.error)}</div>
        <div :if={@comparison_error} class="alert alert-error mb-6">{error_message(@comparison_error)}</div>
        <.compare_form :if={@comparison} comparison={@comparison} />
        <.comparison_report :if={@run.mode == :compare && @run.result} report={@run.result} />
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
            <div :if={@view.metrics != []} class="overflow-x-auto">
              <table class="table table-sm">
                <thead><tr><th>Metric</th><th>Mean</th><th>Coverage</th></tr></thead>
                <tbody>
                  <tr :for={metric <- @view.metrics}>
                    <td>{metric.name}</td><td>{format_number(metric.mean)}</td><td>{format_number(metric.coverage)}</td>
                  </tr>
                </tbody>
              </table>
            </div>
            <p :if={@view.improvement}>Selected score change: {format_number(@view.improvement)}</p>
            <div :if={@view.rows != []} class="overflow-x-auto">
              <h3 class="mb-2 font-semibold">Row results</h3>
              <table class="table table-sm">
                <thead><tr><th>Row</th><th>Execution</th><th>Exact match</th><th>Score</th><th>Expected</th><th>Output</th><th>Details</th></tr></thead>
                <tbody>
                  <tr :for={row <- @view.rows}>
                    <td>{row.id}</td>
                    <td><span class={["badge", row_badge_class(row.status)]}>{execution_label(row.status)}</span></td>
                    <td>{row.match}</td>
                    <td>{format_number(row.score)}</td>
                    <td><code class="text-xs">{inspect(row.expected, limit: 8)}</code></td>
                    <td><code class="text-xs">{inspect(row.output, limit: 8)}</code></td>
                    <td>
                      <details>
                        <summary class="link">Row {row.id} details</summary>
                        <dl class="space-y-2 min-w-44">
                          <dt class="font-semibold">Input</dt>
                          <dd><pre class="whitespace-pre-wrap break-all">{inspect_full(row.input)}</pre></dd>
                          <dt class="font-semibold">Full output</dt>
                          <dd><pre class="whitespace-pre-wrap break-all">{inspect_full(row.output)}</pre></dd>
                          <dt :if={row.responses != []} class="font-semibold">Model responses</dt>
                          <dd :for={response <- row.responses}><pre class="whitespace-pre-wrap break-all">{response}</pre></dd>
                          <dt :if={row.errors != []} class="font-semibold">Errors</dt>
                          <dd :for={error <- row.errors} class="whitespace-pre-wrap break-all">{error}</dd>
                        </dl>
                      </details>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
            <div class="grid gap-4 md:grid-cols-2">
              <div class="rounded-box border border-base-300 p-4">
                <h3 class="font-semibold">Score</h3>
                <.chart
                  id={"#{@run.id}-score-chart"}
                  labels={@view.score_labels}
                  values={@view.score_values}
                />
              </div>
              <div class="rounded-box border border-base-300 p-4">
                <h3 class="font-semibold">Rows</h3>
                <.chart
                  id={"#{@run.id}-rows-chart"}
                  labels={@view.status_labels}
                  values={@view.status_values}
                />
              </div>
            </div>
            <details class="collapse collapse-arrow border border-base-300 bg-base-200">
              <summary class="collapse-title font-medium">Raw result</summary>
              <div class="collapse-content">
                <div class="mockup-code max-h-[32rem] overflow-auto text-xs"><pre class="px-5"><code>{inspect(@run.result, pretty: true, limit: 40, printable_limit: 8_000)}</code></pre></div>
              </div>
            </details>
          </div>
        </section>
        <.run_evidence :if={@run.evidence} run={@run} />
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

    defp run_evidence(assigns) do
      assigns = assign(assigns, :evidence, assigns.run.evidence)

      ~H"""
      <section class="card mb-6 border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body gap-3">
          <h2 class="card-title">Run evidence</h2>
          <p>{@evidence.study_name} · {@evidence.recipe}</p>
          <p>Splits: {Enum.join(@evidence.splits, ", ")}</p>
          <p :if={@run.source_run_id}>
            Search run <a class="link" href={"/runs/#{@run.source_run_id}"}>{@run.source_run_id}</a>
          </p>
          <dl>
            <div :for={{split, dataset} <- Enum.sort(@evidence.datasets)} class="mb-2">
              <dt class="font-medium">{split}</dt>
              <dd :for={{stage, label} <- [source: "Source rows", effective: "Effective cases"]} :if={dataset[stage]}>
                <span>{label} · {dataset[stage].rows}</span>
                <code class="block break-all text-xs">{dataset[stage].fingerprint}</code>
              </dd>
            </div>
          </dl>
          <h3 class="font-semibold">Declared scores</h3>
          <ul>
            <li :for={score <- @evidence.scores}>
              {score.name} · {score.direction} · {score.argument} · {score.metric}
              <span :if={score.range}> · range {inspect(score.range)}</span>
              <span :if={!is_nil(score.failure_score)}> · failure score {score.failure_score}</span>
            </li>
          </ul>
          <p :if={@evidence.selector}>Selection: {inspect(@evidence.selector)}</p>
          <div :if={map_size(@evidence.models) > 0}>
            <h3 class="font-semibold">Declared models</h3>
            <dl>
              <div :for={{role, config} <- Enum.sort(@evidence.models)}>
                <dt>{role} · {config["model"]}</dt>
                <dd class="text-sm">{inspect(Map.delete(config, "model"))}</dd>
              </div>
            </dl>
          </div>
          <div :if={@run.result && @run.mode != :compare}>
            <.successful_models result={@run.result} />
          </div>
        </div>
      </section>
      """
    end

    defp comparison_report(assigns) do
      ~H"""
      <section class="card border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body gap-4">
          <h2 class="card-title">Paired comparison · {@report.split}</h2>
          <div :if={!@report.complete?} class="alert alert-warning">Incomplete comparison</div>
          <div class="grid gap-2 md:grid-cols-2">
            <div :for={{label, evaluation} <- [{"Baseline", @report.baseline}, {"Winner", @report.challenger}]}
                 class="rounded-box border border-base-300 p-3">
              <h3 class="font-semibold">{label}</h3>
              <p>{call_count(evaluation.calls)} calls · {evaluation.usage.total} tokens · {evaluation.stop_reason}</p>
              <p :if={evaluation.metadata[:reported_cost]}>Recorded cost: ${evaluation.metadata.reported_cost}</p>
              <.successful_models result={evaluation} />
            </div>
          </div>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr><th>Metric</th><th>Direction</th><th>Baseline mean</th><th>Winner mean</th><th>Change</th><th>Pairs</th><th>Improved</th><th>Regressed</th><th>Tied</th><th>Errors</th><th>Unpaired</th></tr>
              </thead>
              <tbody>
                <tr :for={{name, metric} <- Enum.sort(@report.metrics)}>
                  <td>{name}</td><td>{metric.direction}</td>
                  <td>{format_number(metric.baseline_mean)}</td><td>{format_number(metric.challenger_mean)}</td>
                  <td>{format_number(metric.delta)}</td>
                  <td>{metric.paired_count}/{length(@report.case_ids)}</td>
                  <td :for={status <- [:improved, :regressed, :tied, :error, :unpaired]}>{Map.get(metric.counts, status, 0)}</td>
                </tr>
              </tbody>
            </table>
          </div>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead><tr><th>Row</th><th>Metric</th><th>Baseline</th><th>Winner</th><th>Outcome</th><th>Evidence</th></tr></thead>
              <tbody>
                <tr :for={{id, name, change} <- comparison_rows(@report)}>
                  <td>{id}</td><td>{name}</td>
                  <td>{format_number(change.baseline)}</td><td>{format_number(change.challenger)}</td>
                  <td><span class={["badge", row_badge_class(change.status)]}>{change.status}</span></td>
                  <td>
                    <details>
                      <summary>Outputs</summary>
                      <.row_output label="Baseline" observation={@report.rows[id].baseline} metric={name} />
                      <.row_output label="Winner" observation={@report.rows[id].challenger} metric={name} />
                    </details>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>
      """
    end

    defp comparison_rows(report) do
      for id <- report.case_ids,
          {name, change} <- Enum.sort(report.rows[id].metrics),
          do: {id, name, change}
    end

    defp row_output(assigns) do
      assigns = assign(assigns, :error, row_error(assigns.observation, assigns.metric))

      ~H"""
      <p class="font-medium">{@label}</p>
      <p :if={!@observation}>No observation</p>
      <div :if={@observation}>
        <p :if={@error} class="text-error">{error_message(@error)}</p>
        <code class="text-xs">{inspect(@observation.output, limit: 8, printable_limit: 250)}</code>
      </div>
      """
    end

    defp row_error(nil, _metric), do: nil

    defp row_error(%{score_errors: errors, error: error}, _metric) when map_size(errors) == 0,
      do: error

    defp row_error(%{score_errors: errors}, metric), do: errors[metric]

    defp successful_models(assigns) do
      assigns = assign(assigns, :models, Tune.UI.Evidence.successful_models(assigns.result))

      ~H"""
      <h4 class="font-medium">Models that returned responses</h4>
      <p :if={@models == []}>None recorded</p>
      <ul><li :for={model <- @models}>{model.role} · {model.model}</li></ul>
      """
    end

    defp assign_run(socket, run) do
      assign(socket,
        run: run,
        view: result_view(run.result),
        duration: duration(run),
        comparison: report_comparison(run),
        comparison_error: nil
      )
    end

    defp report_comparison(%{mode: :tune, status: :completed, result: %Tune.Result{}} = run) do
      comparison_setup(run, Tune.UI.Store.get_study(run.study_id))
    end

    defp report_comparison(_run), do: nil

    defp result_view(nil), do: nil

    defp result_view(%Tune.Evaluation{} = evaluation) do
      {labels, values} = score_series([{"Selected", evaluation.selected_score}])
      evaluation_view(evaluation, labels, values, nil)
    end

    defp result_view(%Tune.Comparison{}), do: nil

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

      if evaluation do
        evaluation_view(evaluation, labels, values, improvement,
          calls: result.calls,
          usage: result.usage,
          stop_reason: result.stop_reason
        )
      end
    end

    defp score_series(entries) do
      entries |> Enum.filter(fn {_label, value} -> is_number(value) end) |> Enum.unzip()
    end

    defp evaluation_view(evaluation, labels, values, improvement, overrides \\ []) do
      statuses = Enum.frequencies_by(evaluation.observations, & &1.status)
      {status_labels, status_values} = Enum.unzip(statuses)

      %{
        score: evaluation.selected_score,
        metrics: Enum.sort_by(Map.values(evaluation.summaries), & &1.name),
        score_labels: labels,
        score_values: values,
        improvement: improvement,
        status_labels: Enum.map(status_labels, &execution_label/1),
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
        match: exact_match(observation),
        input: tune_case && tune_case.input,
        responses: response_texts(observation.prediction),
        errors:
          Enum.map(
            Enum.reject([observation.error | Map.values(observation.score_errors)], &is_nil/1),
            &error_message/1
          ),
        expected: tune_case && tune_case.expected,
        output: observation.output
      }
    end

    defp execution_label(:ok), do: "Completed"
    defp execution_label(status), do: status |> to_string() |> String.capitalize()

    defp exact_match(%{status: :ok, scores: %{exact_match: score}}) when score == 1, do: "Match"

    defp exact_match(%{status: :ok, scores: %{exact_match: score}}) when score == 0,
      do: "Mismatch"

    defp exact_match(_observation), do: "—"

    defp inspect_full(value),
      do: inspect(value, pretty: true, limit: :infinity, printable_limit: :infinity)

    defp response_texts(nil), do: []

    defp response_texts(prediction) do
      for %{response: %ReqLLM.Response{} = response} <- prediction.steps,
          text = ReqLLM.Response.text(response),
          text not in [nil, ""],
          do: text
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

    defp row_badge_class(status) when status in [:ok, :improved], do: "badge-success"
    defp row_badge_class(status) when status in [:error, :regressed], do: "badge-error"
    defp row_badge_class(:tied), do: "badge-ghost"
    defp row_badge_class(_status), do: "badge-warning"
  end
end
