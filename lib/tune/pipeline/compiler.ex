defmodule Tune.Pipeline.Compiler do
  @moduledoc false

  alias Tune.Case
  alias Tune.Comparison
  alias Tune.Dataset
  alias Tune.Error
  alias Tune.Evaluator
  alias Tune.ModelConfig
  alias Tune.Predictor
  alias Tune.Program
  alias Tune.RunLimits
  alias Tune.Runtime.Target
  alias Tune.Score
  alias Tune.Score.Selector
  alias Tune.Search.Study

  @spec preview(map(), map() | {String.t(), map()}) ::
          {:ok, Tune.Prepared.t()} | {:error, Exception.t()}
  def preview(%{} = tune, input) do
    with {:ok, model} <- target_model(tune),
         {:ok, _name, predictor, inputs} <- preview_target(tune.target, input) do
      Predictor.prepare(predictor, inputs, model)
    end
  end

  @spec evaluate(map(), atom()) :: {:ok, Tune.Evaluation.t()} | {:error, Exception.t()}
  def evaluate(%{} = tune, role) do
    study = Study.new(limits: Map.delete(run_limits(tune), :evaluations))

    with {:ok, selector} <- evaluation_selector(tune),
         do: evaluate_split(tune, role, selector, study)
  rescue
    error in [Error.Invalid.Dataset, Error.Invalid.Definition] -> {:error, error}
  end

  @spec compare(Tune.t(), Tune.Result.t() | Tune.Artifact.t(), atom()) ::
          {:ok, Comparison.t()} | {:error, Exception.t()}
  def compare(%{runner: :replay}, _winner, _split),
    do: invalid(:compare, "saved rows support evaluation only. Use Tune.evaluate/1")

  def compare(tune, candidate, split) do
    study = Study.new(limits: Map.drop(run_limits(tune), [:cases, :evaluations]))

    with {:ok, selector} <- evaluation_selector(tune),
         {:ok, factory} <- Dataset.factory(tune.data, split) do
      compare_split(tune, candidate, split, factory, selector, study)
    end
  rescue
    error in Error.Invalid.Dataset -> {:error, error}
  end

  defp comparison_target(%Tune.Result{value: value}, _target), do: {:ok, value}
  defp comparison_target(%Tune.Artifact{} = artifact, target), do: Tune.load(artifact, target)

  defp compare_split(tune, candidate, split, factory, selector, study) do
    limits = Map.put(Study.evaluation_limits(study), :cases, tune.limits[:cases])

    with :ok <- check_comparison(study),
         {:ok, winner} <- comparison_target(candidate, tune.target),
         {:ok, original_runner, signature} <- runner(tune),
         {:ok, winner_runner, winner_signature} <- runner(%{tune | target: winner}),
         :ok <- compatible_signatures(signature, winner_signature),
         {:ok, rows, truncated?} <- Dataset.snapshot(factory, split, limits),
         :ok <- require_comparison_cases(rows, limits[:cases]),
         {:ok, rows} <- normalize_comparison_cases(signature, rows) do
      Dataset.report(limits, split, :effective, rows)
      baseline = compare_target(tune, original_runner, rows, selector, study, truncated?)
      study = Study.account_score(study, baseline)
      challenger = compare_target(tune, winner_runner, rows, selector, study, truncated?)
      {:ok, Comparison.build(split, rows, tune.scores, baseline, challenger)}
    else
      {:stopped, reason} -> stopped_comparison(tune, split, selector, study, reason)
      {:error, _error} = error -> error
    end
  end

  defp compatible_signatures(nil, nil), do: :ok

  defp compatible_signatures(original, winner) do
    if Program.same_fields?(original, winner),
      do: :ok,
      else:
        invalid(
          :compare,
          "the challenger must have the same input and output fields as the original"
        )
  end

  defp check_comparison(study) do
    case comparison_stop(study) do
      nil -> :ok
      reason -> {:stopped, reason}
    end
  end

  defp stopped_comparison(tune, split, selector, study, reason) do
    stopped = Evaluator.stopped([], tune.scores, selector, Study.evaluation_limits(study), reason)
    {:ok, Comparison.build(split, [], tune.scores, stopped, stopped)}
  end

  defp compare_target(tune, runner, rows, selector, study, truncated?) do
    limits = Map.put(Study.evaluation_limits(study), :source_truncated?, truncated?)

    case comparison_stop(study) do
      nil ->
        Evaluator.evaluate(rows, runner, tune.scores, selector, limits)

      reason ->
        Evaluator.stopped(rows, tune.scores, selector, limits, reason)
    end
  end

  defp comparison_stop(study) do
    case Study.stop_reason(study) || Study.limit_reason(study) do
      :budget_exhausted -> :model_call_limit
      reason -> reason
    end
  end

  defp require_comparison_cases([], limit) when limit != 0,
    do: invalid(:data, "comparison data is empty")

  defp require_comparison_cases(_rows, _limit), do: :ok

  defp normalize_comparison_cases(_signature, []), do: {:ok, []}
  defp normalize_comparison_cases(signature, rows), do: Case.compare_rows(signature, rows)

  defp evaluate_split(tune, split, selector, study) do
    limits = Study.evaluation_limits(study)

    with :ok <- RunLimits.check(limits),
         {:ok, factory} <- Dataset.factory(tune.data, split),
         {:ok, runner, signature} <- runner(tune),
         {:ok, source, limits} <- evaluation_data(signature, split, factory, limits) do
      {:ok, Evaluator.evaluate(source, runner, tune.scores, selector, limits)}
    else
      {:error, _error} = error -> error
      {:stopped, reason} -> {:ok, Evaluator.stopped([], tune.scores, selector, limits, reason)}
    end
  end

  @spec tune(map()) :: {:ok, Tune.Result.t()} | {:error, Exception.t()}
  def tune(%{runner: nil} = tune) do
    with :ok <- require_program_target(tune),
         {:ok, optimizer} <- optimizer(tune.strategy) do
      Tune.Search.Program.run(tune, optimizer, run_limits(tune))
    end
  end

  def tune(%{runner: :replay}), do: invalid(:search, "saved rows support evaluation only")

  def tune(%{} = tune) do
    with {:ok, strategy, opts} <- generic_strategy(tune.strategy),
         :ok <- require_score_call_limit(tune),
         {:ok, spaces} <- compile_spaces(strategy, tune.variations, opts),
         {:ok, data_factory} <- Dataset.factory(tune.data, :validation),
         {:ok, selector} <- compiled_selector(tune) do
      strategy.run(
        tune.target,
        tune.runner,
        data_factory,
        spaces,
        tune.scores,
        selector,
        run_limits(tune),
        opts
      )
    end
  rescue
    error in [Error.Invalid.Dataset, Error.Invalid.Definition] -> {:error, error}
  end

  defp evaluation_selector(%{scores: [_, _ | _], selector: nil}), do: {:ok, nil}
  defp evaluation_selector(tune), do: compiled_selector(tune)

  defp compiled_selector(%{scores: []}),
    do: invalid(:scores, "at least one score is required")

  defp compiled_selector(%{} = tune), do: Selector.compile(tune.scores, tune.selector)

  defp run_limits(%{runner: :replay} = tune) do
    limits = callback_limits(tune)

    if Enum.any?(tune.scores, &Score.model_calls?/1),
      do: Map.put(limits, :call_role, :judge),
      else: Map.drop(limits, [:model_calls, :row_calls])
  end

  defp run_limits(tune), do: callback_limits(tune)

  defp callback_limits(tune) do
    Map.merge(tune.limits, %{on_progress: tune.on_progress, cancel: tune.cancel})
  end

  defp runtime_options(tune) do
    opts =
      []
      |> put_model_options(tune.models)
      |> put_option(:max_steps, tune.limits[:steps])
      |> put_option(:timeout, tune.limits[:deadline])

    Tune.Runtime.normalize_options(opts)
  end

  defp optimizer(nil), do: invalid(:search, "Tune.search/3 is required")

  defp optimizer({strategy, opts}) do
    case Tune.Search.Program.Registry.fetch(strategy) do
      nil -> invalid(:search, "unknown search strategy #{inspect(strategy)}")
      module -> {:ok, {module, opts}}
    end
  end

  defp generic_strategy({:genetic, opts}), do: {:ok, Tune.Search.Genetic, opts}
  defp generic_strategy({:grid, opts}), do: {:ok, Tune.Search.Grid, opts}
  defp generic_strategy(nil), do: invalid(:search, "Tune.search/3 is required")

  defp generic_strategy({strategy, _opts}),
    do: invalid(:search, "#{inspect(strategy)} does not support a generic target")

  defp compile_spaces(Tune.Search.Grid, variations, _opts), do: {:ok, variations}

  defp compile_spaces(Tune.Search.Genetic, variations, opts) when map_size(variations) == 0 do
    if Keyword.has_key?(opts, :initial_population),
      do: {:ok, %{}},
      else: invalid(:vary, "at least one variation is required")
  end

  defp compile_spaces(Tune.Search.Genetic, variations, _opts) do
    Enum.reduce_while(variations, {:ok, %{}}, fn {name, descriptor}, {:ok, acc} ->
      case Tune.Space.new(descriptor) do
        {:ok, space} -> {:cont, {:ok, Map.put(acc, name, space)}}
        error -> {:halt, error}
      end
    end)
  end

  defp target_model(tune) do
    case Map.fetch(tune.models, :model) do
      {:ok, config} -> ModelConfig.new(config)
      :error -> invalid(:model, "a target model is required")
    end
  end

  defp preview_target(target, {name, inputs}) when is_binary(name) and is_map(inputs) do
    with {:ok, parameters} <- Program.parameters(target),
         {:ok, %Predictor{} = predictor} <- Map.fetch(parameters, name) do
      {:ok, name, predictor, inputs}
    else
      :error -> invalid(:preview, "unknown predictor #{inspect(name)}")
      {:ok, _} -> invalid(:preview, "#{inspect(name)} is not a predictor")
      error -> error
    end
  end

  defp preview_target(%Predictor{} = predictor, inputs) when is_map(inputs),
    do: {:ok, "root", predictor, inputs}

  defp preview_target(_target, _input),
    do: invalid(:preview, "a composed program requires {predictor_name, inputs}")

  defp require_program_target(%{runner: nil, target: target}) do
    with {:ok, _parameters} <- Program.parameters(target), do: :ok
  end

  defp evaluation_data(%Tune.Signature{}, _split, _factory, %{cases: 0} = limits),
    do: {:ok, [], Map.put(limits, :source_truncated?, true)}

  defp evaluation_data(%Tune.Signature{} = signature, split, factory, limits) do
    with {:ok, rows, truncated?} <- Dataset.snapshot(factory, split, limits),
         {:ok, cases} <- Case.normalize_all(signature, rows) do
      Dataset.report(limits, split, :effective, cases)
      {:ok, cases, Map.put(limits, :source_truncated?, truncated?)}
    end
  end

  defp evaluation_data(nil, split, factory, limits),
    do: {:ok, {:dataset, factory, split}, Map.put(limits, :dataset_split, split)}

  defp runner(%{runner: nil} = tune) do
    with {:ok, run_options} <- runtime_options(tune),
         {:ok, target} <- Target.new(tune.target, run_options) do
      {:ok,
       fn tune_case ->
         Target.run(target, tune_case.input,
           role: :target,
           max_model_calls: Map.get(tune_case.metadata, :model_call_allowance)
         )
       end, target.signature}
    end
  end

  defp runner(%{runner: :replay}), do: {:ok, &Tune.Replay.output/1, nil}

  defp runner(%{runner: runner, target: target}) do
    {:ok, fn tune_case -> Tune.Search.Generic.invoke(runner, target, tune_case) end, nil}
  end

  defp put_model_options(opts, models) do
    Enum.reduce(models, opts, fn {key, value}, acc -> Keyword.put(acc, key, value) end)
  end

  defp put_option(opts, _key, nil), do: opts
  defp put_option(opts, key, value), do: Keyword.put(opts, key, value)

  defp require_score_call_limit(%{} = tune) do
    if Enum.any?(tune.scores, &Score.model_calls?/1) and
         not is_integer(tune.limits[:model_calls]),
       do: invalid(:model_calls, "an explicit model call limit is required"),
       else: :ok
  end

  defp invalid(option, message),
    do: {:error, Error.Invalid.Option.exception(option: option, message: message)}
end
