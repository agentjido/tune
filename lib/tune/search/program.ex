defmodule Tune.Search.Program do
  @moduledoc false

  alias Tune
  alias Tune.Case
  alias Tune.Dataset
  alias Tune.Error
  alias Tune.Result
  alias Tune.Score.Selector
  alias Tune.Search.Program.Context
  alias Tune.Search.Study

  @spec run(Tune.t(), {module(), keyword()}, map()) :: {:ok, Result.t()} | {:error, Exception.t()}
  def run(%Tune{target: program} = tune, {module, options}, limits) do
    study = Study.new(limits: limits, seed: Map.get(limits, :seed, 0))
    dataset_limits = Study.evaluation_limits(study)

    with {:ok, config} <- optimizer_config(module, options),
         {:ok, requirements} <- requirements(module, config),
         {:ok, selector} <- selector(tune.scores, tune.selector, requirements),
         :ok <- max_calls(limits, requirements, tune.scores),
         {:ok, run_options} <- run_options(tune, requirements),
         {:ok, signature} <- Tune.Program.signature(program),
         {:ok, _parameters} <- Tune.Program.parameters(program),
         :ok <- check_start(study),
         {:ok, train} <- load_split(signature, tune.data, :train, requirements, dataset_limits),
         {train, duplicates} <- deduplicate_train(train),
         :ok <- report_split(tune.data, :train, train, limits),
         :ok <- check_start(study),
         {:ok, validation} <-
           load_split(signature, tune.data, :validation, requirements, dataset_limits),
         :ok <- report_split(tune.data, :validation, validation, limits),
         :ok <- check_start(study),
         :ok <- check_overlap(train, validation) do
      ctx =
        Context.new(
          optimizer: module,
          failure_score: if(selector, do: Selector.failure_score(tune.scores, selector)),
          scores: tune.scores,
          selector: selector,
          run_options: run_options,
          study: study,
          train: train,
          validation: validation
        )
        |> Context.note(:train_duplicates_removed, duplicates)
        |> Context.note(:settings, settings(config))

      case module.compile(config, program, ctx) do
        {:ok, optimized, ctx} ->
          {:ok, result(ctx, optimized, true)}

        {:error, %Error.Optimization.Failed{} = error, ctx} ->
          {:error, %{error | report: result(ctx, nil, false)}}

        {:error, cause, ctx} ->
          {:error,
           Error.Optimization.Failed.exception(
             message: "optimization failed: #{describe(cause)}",
             cause: cause,
             report: result(ctx, nil, false)
           )}
      end
    else
      {:stopped, reason} ->
        {:error,
         Error.Optimization.Failed.exception(
           message: "optimization stopped before search",
           cause: Context.limit_error(reason),
           report: Study.result(Study.stop(study, reason), nil, %{})
         )}

      {:error, _error} = error ->
        error
    end
  rescue
    error in Error.Invalid.Dataset -> {:error, error}
  end

  defp check_start(study) do
    case Study.limit_reason(study) do
      reason when reason in [:deadline, :cancelled] -> {:stopped, reason}
      _ -> :ok
    end
  end

  defp result(%Context{} = ctx, value, ok?) do
    parameters =
      case value && Tune.Program.parameters(value) do
        {:ok, parameters} -> parameters
        _ -> %{}
      end

    Context.result(ctx, value, parameters,
      complete?: ok? and Context.stop_reason(ctx) == nil,
      stop_reason: Context.stop_reason(ctx) || if(ok?, do: :completed, else: :failed),
      metadata: %{
        strategy: ctx.optimizer,
        seed: Context.seed(ctx),
        max_model_calls: Context.max_model_calls(ctx),
        models: describe_models(Keyword.fetch!(ctx.run_options, :models)),
        datasets: %{
          train: length(ctx.train),
          validation: length(ctx.validation),
          train_fingerprint: fingerprint(ctx.train),
          validation_fingerprint: fingerprint(ctx.validation)
        },
        notes: Context.notes(ctx)
      }
    )
  end

  defp settings(config) when is_map(config) do
    config
    |> Enum.filter(fn {_key, value} -> portable?(value) end)
    |> Map.new(fn {key, value} -> {to_string(key), portable(value)} end)
  end

  defp settings(_config), do: %{}

  defp describe_models(models) do
    Map.new(models, fn {role, config} ->
      {Atom.to_string(role), Tune.ModelConfig.describe(config)}
    end)
  end

  defp portable?(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: true

  defp portable?(value) when is_atom(value), do: true
  defp portable?(value) when is_list(value), do: Enum.all?(value, &portable?/1)
  defp portable?(_value), do: false

  defp portable(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp portable(value) when is_list(value), do: Enum.map(value, &portable/1)
  defp portable(value), do: value

  defp fingerprint([]), do: nil

  defp fingerprint(examples) do
    examples
    |> Enum.map(&[&1.id, &1.input, &1.expected])
    |> Tune.CanonicalJSON.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp optimizer_config(module, options) do
    if Code.ensure_loaded?(module) and function_exported?(module, :compile, 3) and
         function_exported?(module, :init, 1) and function_exported?(module, :requirements, 1),
       do: module.init(options),
       else:
         option_error(:search, "#{inspect(module)} must implement Tune.Search.ProgramStrategy")
  end

  defp requirements(module, config) do
    requirements = module.requirements(config)

    case requirements.datasets -- [:train, :validation] do
      [] -> {:ok, requirements}
      [split | _] -> option_error(:search, "unknown required dataset split #{inspect(split)}")
    end
  end

  defp run_options(tune, requirements) do
    opts = [{:max_steps, tune.limits[:steps]} | Map.to_list(tune.models)]

    with {:ok, options} <- Tune.Runtime.normalize_options(opts) do
      models = Keyword.fetch!(options, :models)

      case Enum.find(requirements.roles, &(not Map.has_key?(models, &1))) do
        nil ->
          {:ok, Keyword.drop(options, [:role, :max_model_calls])}

        role ->
          option_error(role, "this optimizer requires an explicit #{role} model configuration")
      end
    end
  end

  defp selector([], _selector, %{metric?: false}), do: {:ok, nil}
  defp selector(scores, selector, _requirements), do: Selector.compile(scores, selector)

  defp max_calls(limits, requirements, scores) do
    if (requirements.model_calls? or Enum.any?(scores, &Tune.Score.model_calls?/1)) and
         is_nil(limits[:model_calls]),
       do:
         option_error(:model_calls, "a model call limit is required for search with model calls"),
       else: :ok
  end

  defp load_split(signature, data, split, requirements, limits) do
    if is_map_key(data, split) or split in requirements.datasets do
      with {:ok, factory} <- Dataset.factory(data, split) do
        snapshot(signature, factory, limits, split)
      end
    else
      {:ok, []}
    end
  end

  defp deduplicate_train(cases) do
    unique = Enum.uniq_by(cases, &{Case.input_key(&1), Tune.CanonicalJSON.encode!(&1.expected)})
    {unique, length(cases) - length(unique)}
  end

  defp report_split(data, split, cases, limits) do
    if is_map_key(data, split), do: Dataset.report(limits, split, :effective, cases)
    :ok
  end

  defp snapshot(_signature, _factory, %{cases: 0} = limits, role) do
    Dataset.report(limits, role, :source, [])
    {:ok, []}
  end

  defp snapshot(signature, factory, limits, role) do
    with {:ok, rows, _truncated?} <- Dataset.snapshot(factory, role, limits, :prefix) do
      Case.normalize_all(signature, rows)
    end
  end

  defp check_overlap(train, validation) do
    train_keys = MapSet.new(train, &Case.input_key/1)

    case Enum.filter(validation, &MapSet.member?(train_keys, Case.input_key(&1))) do
      [] ->
        :ok

      overlapping ->
        {:error,
         Error.Invalid.Definition.exception(
           message:
             "#{length(overlapping)} validation rows have the same inputs as training rows",
           details: Enum.map(overlapping, & &1.id)
         )}
    end
  end

  defp describe(%{__exception__: true} = error), do: Exception.message(error)
  defp describe(error), do: inspect(error)

  defp option_error(option, message),
    do: {:error, Error.Invalid.Option.exception(option: option, message: message)}
end
