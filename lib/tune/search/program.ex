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

  @options [
    :optimizer,
    :trainset,
    :valset,
    :scores,
    :selector,
    :model,
    :teacher,
    :proposal,
    :max_steps,
    :limits
  ]

  @spec run(Tune.Program.t(), keyword()) :: {:ok, Result.t()} | {:error, Exception.t()}
  def run(program, opts) do
    limits = Keyword.fetch!(opts, :limits)
    study = Study.new(limits: limits, seed: Map.get(limits, :seed, 0))

    with :ok <- check_keys(opts),
         {:ok, module, config} <- optimizer(opts),
         requirements = module.requirements(config),
         scores = Keyword.fetch!(opts, :scores),
         {:ok, selector} <- selector(scores, opts[:selector], requirements),
         :ok <- max_calls(limits, requirements, scores),
         {:ok, run_options} <- run_options(opts, requirements),
         {:ok, signature} <- Tune.Program.signature(program),
         {:ok, _parameters} <- Tune.Program.parameters(program),
         :ok <- check_start(study),
         {:ok, trainset, duplicates} <- trainset(signature, opts, requirements, limits),
         :ok <- check_start(study),
         {:ok, valset} <- valset(signature, opts, requirements, limits),
         :ok <- check_start(study),
         :ok <- check_overlap(trainset, valset) do
      ctx =
        Context.new(
          optimizer: module,
          failure_score: if(selector, do: Selector.failure_score(scores, selector)),
          scores: scores,
          selector: selector,
          run_options: run_options,
          study: study,
          trainset: trainset,
          valset: valset
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
        datasets: %{
          train: length(ctx.trainset),
          validation: length(ctx.valset),
          train_fingerprint: fingerprint(ctx.trainset),
          validation_fingerprint: fingerprint(ctx.valset)
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

  defp check_keys(opts) do
    case Keyword.keys(opts) -- @options do
      [] -> :ok
      [key | _] -> option_error(key, "unknown optimize option")
    end
  end

  defp optimizer(opts) do
    {module, config} =
      case Keyword.get(opts, :optimizer) do
        {module, config} when is_atom(module) and is_list(config) -> {module, config}
        module when is_atom(module) and not is_nil(module) -> {module, []}
        other -> {other, nil}
      end

    cond do
      config == nil ->
        option_error(:optimizer, "must be a module or {module, options}")

      not (Code.ensure_loaded?(module) and function_exported?(module, :compile, 3) and
             function_exported?(module, :init, 1) and function_exported?(module, :requirements, 1)) ->
        option_error(:optimizer, "#{inspect(module)} is not a Tune.Search.ProgramStrategy")

      true ->
        with {:ok, config} <- module.init(config), do: {:ok, module, config}
    end
  end

  defp run_options(opts, requirements) do
    run_keys = [:model, :teacher, :proposal, :max_steps]

    with {:ok, options} <- Tune.Runtime.normalize_options(Keyword.take(opts, run_keys)) do
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

  defp trainset(signature, opts, requirements, limits) do
    case Keyword.get(opts, :trainset) do
      nil ->
        if :train in requirements.datasets,
          do: option_error(:trainset, "is required"),
          else: {:ok, [], 0}

      factory ->
        with {:ok, examples} <- snapshot(signature, factory, limits, :train) do
          unique =
            Enum.uniq_by(examples, &{Case.input_key(&1), Tune.CanonicalJSON.encode!(&1.expected)})

          Dataset.report(limits, :train, :effective, unique)
          {:ok, unique, length(examples) - length(unique)}
        end
    end
  end

  defp valset(signature, opts, requirements, limits) do
    case Keyword.fetch(opts, :valset) do
      :error ->
        if :val in requirements.datasets,
          do: option_error(:valset, "is required; there is no automatic split"),
          else: {:ok, []}

      {:ok, factory} ->
        with {:ok, cases} <- snapshot(signature, factory, limits, :validation) do
          Dataset.report(limits, :validation, :effective, cases)
          {:ok, cases}
        end
    end
  end

  defp snapshot(_signature, _factory, %{cases: 0} = limits, role) do
    Dataset.report(limits, role, :source, [])
    {:ok, []}
  end

  defp snapshot(signature, factory, limits, role) do
    rows = factory.() |> Dataset.prefix(limits[:cases]) |> Dataset.capture_source(limits, role)
    Case.normalize_all(signature, rows)
  rescue
    error -> option_error(:data, "could not read data: #{Exception.message(error)}")
  end

  defp check_overlap(trainset, valset) do
    train_keys = MapSet.new(trainset, &Case.input_key/1)

    case Enum.filter(valset, &MapSet.member?(train_keys, Case.input_key(&1))) do
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
