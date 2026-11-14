defmodule Tune.Examples.Comparison do
  @moduledoc """
  Baseline-versus-optimized comparison per fixed target configuration.

  For each named target configuration, the comparison:

    1. evaluates the unchanged program on the test set,
    2. optimizes it with that target configuration fixed,
    3. evaluates the optimized program on the same test set,
    4. renders a prompt preview for every predictor,
    5. dumps, encodes, decodes, and applies the learned parameters to a fresh
       program, and checks the reloaded program equals the optimized one.

  It reports scores, eligibility, parse success, attempted managed calls,
  and provider-reported tokens. It uses only public APIs. Scores are
  measurements of this run, not claims about any optimizer or model.
  """

  alias Tune
  alias Tune.Error
  alias Tune.Evaluation
  alias Tune.ModelConfig
  alias Tune.Parameters
  alias Tune.Predictor
  alias Tune.Result

  @doc """
  Runs the comparison.

  `new_program` builds a fresh program. `targets` is a list of
  `{name, model_config_options}`. Options: `:optimizer`, `:trainset`,
  `:valset`, `:testset`, `:metric`, `:teacher`, `:proposal`,
  `:max_model_calls`, `:seed`, `:failure_score`, `:timeout`, and `:row_timeout`.
  """
  @spec run((-> Tune.t()), [{String.t(), keyword()}], keyword()) :: [map()]
  def run(new_program, targets, opts) do
    Enum.map(targets, fn {name, target} -> compare(name, new_program, target, opts) end)
  end

  @doc "Formats comparison rows as a plain-text table."
  @spec table([map()]) :: String.t()
  def table(rows) do
    header =
      "target | model | adapter | baseline | optimized | eligible | parse ok | calls | tokens | reload"

    lines =
      Enum.map(rows, fn row ->
        Enum.join(
          [
            row.name,
            row.model,
            row.adapter,
            score(row.baseline.selection_score),
            score(row.optimized && row.optimized.selection_score),
            to_string(row.optimized && row.optimized.eligible?),
            "#{percent(row.baseline.parse_success)} -> #{percent(row.optimized && row.optimized.parse_success)}",
            to_string(row.calls),
            to_string(row.tokens),
            to_string(row.reloaded?)
          ],
          " | "
        )
      end)

    Enum.join([header | lines], "\n")
  end

  defp compare(name, new_program, target, opts) do
    {:ok, config} = ModelConfig.new(target)

    eval_opts =
      [
        model: config,
        metric: Keyword.fetch!(opts, :metric),
        failure_score: Keyword.get(opts, :failure_score)
      ] ++ Keyword.take(opts, [:timeout, :row_timeout])

    testset = Keyword.fetch!(opts, :testset)
    {:ok, baseline} = Tune.evaluate(new_program.(), testset, eval_opts)

    optimize_opts =
      [
        optimizer: Keyword.fetch!(opts, :optimizer),
        trainset: Keyword.fetch!(opts, :trainset),
        valset: Keyword.fetch!(opts, :valset),
        metric: Keyword.fetch!(opts, :metric),
        model: config,
        max_model_calls: Keyword.fetch!(opts, :max_model_calls),
        seed: Keyword.get(opts, :seed, 0)
      ] ++ Keyword.take(opts, [:teacher, :proposal, :failure_score, :timeout, :row_timeout])

    describe = ModelConfig.describe(config)

    base = %{
      name: name,
      model: describe["model"],
      adapter: describe["adapter"],
      baseline: summary(baseline)
    }

    case Tune.optimize(new_program.(), optimize_opts) do
      {:ok, optimized, report} ->
        {:ok, after_eval} = Tune.evaluate(optimized, testset, eval_opts)

        Map.merge(base, %{
          optimized: summary(after_eval),
          optimized_program: optimized,
          report: report,
          calls:
            baseline.calls + Tune.Optimizer.Report.total_calls(report) +
              after_eval.calls,
          tokens: tokens(baseline) + report.usage.total + tokens(after_eval),
          prompts: previews(optimized, after_eval, config),
          reloaded?: reload(new_program, optimized, report, config)
        })

      {:error, %Error.Optimization.Failed{report: report} = error} ->
        Map.merge(base, %{
          optimized: nil,
          error: error,
          report: report,
          calls: baseline.calls + Tune.Optimizer.Report.total_calls(report),
          tokens: tokens(baseline) + report.usage.total,
          prompts: %{},
          reloaded?: false
        })
    end
  end

  defp summary(%Evaluation{} = evaluation) do
    %{
      selection_score: evaluation.selection_score,
      mean: evaluation.mean,
      coverage: evaluation.coverage,
      eligible?: evaluation.eligible?,
      parse_success: parse_success(evaluation),
      calls: evaluation.calls,
      tokens: tokens(evaluation)
    }
  end

  defp parse_success(%Evaluation{rows: rows}) do
    attempted = Enum.filter(rows, &(&1.status in [:ok, :error]))
    parsed = Enum.reject(attempted, &output_error?(&1.error))
    if attempted == [], do: nil, else: length(parsed) / length(attempted)
  end

  defp output_error?(%Error.Execution.Failed{cause: cause}), do: output_error?(cause)
  defp output_error?(%Error.Output.Parse{}), do: true
  defp output_error?(%Error.Output.Invalid{}), do: true
  defp output_error?(%Error.Output.Rejected{}), do: true
  defp output_error?(_), do: false

  defp tokens(%Evaluation{rows: rows}) do
    rows
    |> Enum.map(fn
      %{result: %Result{} = result} -> Result.token_totals(result).total
      _ -> 0
    end)
    |> Enum.sum()
  end

  defp previews(program, %Evaluation{rows: rows}, config) do
    case Enum.find(rows, &(&1.status == :ok)) do
      nil ->
        %{}

      %{result: result} ->
        {:ok, parameters} = Tune.parameters(program)

        for step <- result.steps,
            %Predictor{} = predictor <- [Map.get(parameters, step.name)],
            into: %{} do
          {:ok, prepared} = Predictor.prepare(predictor, step.inputs, config)

          {step.name,
           Enum.map(prepared.context.messages, fn m ->
             {m.role, Enum.map_join(m.content, "", & &1.text)}
           end)}
        end
    end
  end

  defp reload(new_program, optimized, report, config) do
    provenance =
      Parameters.provenance(source: "comparison", report: report, models: [target: config])

    with {:ok, artifact} <- Parameters.dump(optimized, provenance: provenance),
         {:ok, json} <- Parameters.encode(artifact),
         {:ok, decoded} <- Parameters.decode(json),
         {:ok, loaded} <- Parameters.apply(new_program.(), decoded) do
      {:ok, Tune.parameters(loaded)} == {:ok, Tune.parameters(optimized)}
    else
      _ -> false
    end
  end

  defp score(nil), do: "-"
  defp score(value), do: :erlang.float_to_binary(value * 1.0, decimals: 3)

  defp percent(nil), do: "-"
  defp percent(value), do: "#{round(value * 100)}%"
end
