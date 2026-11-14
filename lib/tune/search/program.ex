defmodule Tune.Search.Program do
  @moduledoc false

  alias Tune
  alias Tune.Error
  alias Tune.Example
  alias Tune.Metric
  alias Tune.Result
  alias Tune.Search.Context

  @options [
    :optimizer,
    :trainset,
    :valset,
    :metric,
    :failure_score,
    :scores,
    :selector,
    :model,
    :teacher,
    :proposal,
    :max_model_calls,
    :seed,
    :max_steps,
    :timeout,
    :row_timeout
  ]

  @spec run(Tune.Program.t(), keyword()) :: {:ok, Result.t()} | {:error, Exception.t()}
  def run(program, opts) do
    with :ok <- reject_testset(opts),
         :ok <- check_keys(opts),
         {:ok, module, config} <- optimizer(opts),
         requirements = module.requirements(config),
         {:ok, run_options} <- run_options(opts, requirements),
         {:ok, signature} <- Tune.Program.signature(program),
         {:ok, _parameters} <- Tune.Program.parameters(program),
         {:ok, metric} <- metric(opts, requirements),
         {:ok, failure_score} <- failure_score(opts),
         {:ok, max_calls} <- max_calls(opts, requirements),
         {:ok, seed} <- seed(opts),
         {:ok, trainset, duplicates} <- trainset(signature, opts, requirements),
         {:ok, valset} <- valset(signature, opts, requirements),
         :ok <- check_overlap(trainset, valset) do
      ctx =
        Context.new(
          optimizer: module,
          metric: metric,
          failure_score: failure_score,
          scores: Keyword.get(opts, :scores, []),
          selector: Keyword.get(opts, :selector),
          run_options: run_options,
          max_model_calls: max_calls,
          seed: seed,
          row_timeout: Keyword.get(opts, :row_timeout, 120_000),
          deadline: Keyword.get(opts, :timeout),
          trainset: trainset,
          valset: valset,
          notes: %{train_duplicates_removed: duplicates, settings: settings(config)}
        )

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
    end
  end

  defp result(%Context{} = ctx, value, ok?) do
    parameters =
      case value && Tune.Program.parameters(value) do
        {:ok, parameters} -> parameters
        _ -> %{}
      end

    Context.result(ctx, value, parameters,
      complete?: ok? and ctx.stop_reason == nil,
      stop_reason: ctx.stop_reason || if(ok?, do: :completed, else: :failed),
      metadata: %{
        strategy: ctx.optimizer,
        seed: ctx.seed,
        max_model_calls: ctx.max_model_calls,
        datasets: %{
          train: length(ctx.trainset),
          validation: length(ctx.valset),
          train_fingerprint: fingerprint(ctx.trainset),
          validation_fingerprint: fingerprint(ctx.valset)
        },
        notes: ctx.notes
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
    |> Enum.map(&[&1.id, &1.inputs, &1.labels])
    |> Example.canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp reject_testset(opts) do
    if Keyword.has_key?(opts, :testset),
      do: option_error(:testset, "test data is only accepted by Tune.evaluate/3"),
      else: :ok
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
    run_keys = [:model, :teacher, :proposal, :max_steps, :timeout]

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

  defp metric(opts, requirements) do
    case Keyword.fetch(opts, :metric) do
      {:ok, metric} ->
        Metric.new(metric)

      :error ->
        if Map.get(requirements, :metric?, true),
          do: option_error(:metric, "is required"),
          else: {:ok, nil}
    end
  end

  defp failure_score(opts) do
    case Keyword.get(opts, :failure_score) do
      nil -> {:ok, nil}
      score when is_number(score) -> {:ok, score}
      _ -> option_error(:failure_score, "must be a number")
    end
  end

  defp max_calls(opts, requirements) do
    case {Keyword.get(opts, :max_model_calls), requirements.model_calls?} do
      {nil, true} ->
        option_error(:max_model_calls, "is required for an optimizer that calls models")

      {nil, false} ->
        {:ok, nil}

      {value, _} when is_integer(value) and value >= 0 ->
        {:ok, value}

      _ ->
        option_error(:max_model_calls, "must be a nonnegative integer")
    end
  end

  defp seed(opts) do
    case Keyword.get(opts, :seed, 0) do
      seed when is_integer(seed) -> {:ok, seed}
      _ -> option_error(:seed, "must be an integer")
    end
  end

  defp trainset(signature, opts, requirements) do
    case Keyword.get(opts, :trainset) do
      nil ->
        if :train in requirements.datasets,
          do: option_error(:trainset, "is required"),
          else: {:ok, [], 0}

      rows ->
        with {:ok, examples} <- Example.normalize_all(signature, rows) do
          unique =
            Enum.uniq_by(examples, &{Example.input_key(&1), Example.canonical_json(&1.labels)})

          {:ok, unique, length(examples) - length(unique)}
        end
    end
  end

  defp valset(signature, opts, requirements) do
    case Keyword.get(opts, :valset) do
      nil ->
        if :val in requirements.datasets,
          do: option_error(:valset, "is required; there is no automatic split"),
          else: {:ok, []}

      rows ->
        Example.normalize_all(signature, rows)
    end
  end

  defp check_overlap(trainset, valset) do
    train_keys = MapSet.new(trainset, &Example.input_key/1)

    case Enum.filter(valset, &MapSet.member?(train_keys, Example.input_key(&1))) do
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
