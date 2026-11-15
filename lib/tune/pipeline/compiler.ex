defmodule Tune.Pipeline.Compiler do
  @moduledoc false

  alias Tune.Case
  alias Tune.Error
  alias Tune.ModelConfig
  alias Tune.Predictor
  alias Tune.Program
  alias Tune.Runtime.Target
  alias Tune.Score
  alias Tune.Score.Selector

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
    with {:ok, rows} <- dataset(tune, role),
         {:ok, selector} <- compiled_selector(tune),
         {:ok, source, runner} <- evaluation_runner(tune, rows) do
      {:ok, Tune.Evaluator.evaluate(source, runner, tune.scores, selector, tune.limits)}
    end
  end

  @spec tune(map()) :: {:ok, Tune.Result.t()} | {:error, Exception.t()}
  def tune(%{runner: nil} = tune) do
    with :ok <- require_program_target(tune),
         {:ok, optimizer} <- optimizer(tune.strategy),
         {:ok, requirements} <- optimizer_requirements(optimizer),
         {:ok, datasets} <- optimization_datasets(tune),
         {:ok, metric, failure_score, selector} <-
           selected_metric(tune, requirements.metric?),
         {:ok, opts} <-
           optimize_options(tune, optimizer, datasets, metric, failure_score, selector),
         {:ok, result} <- Tune.Search.Program.run(tune.target, opts) do
      {:ok, put_in(result.metadata[:models], describe_models(tune.models))}
    end
  end

  def tune(%{} = tune) do
    with {:ok, opts} <- genetic_strategy(tune.strategy),
         :ok <- require_score_call_limit(tune),
         {:ok, spaces} <- compile_spaces(tune.variations),
         {:ok, data_factory} <- data_factory(tune, :validation),
         {:ok, selector} <- compiled_selector(tune) do
      Tune.Search.Genetic.run(
        tune.target,
        tune.runner,
        data_factory,
        spaces,
        tune.scores,
        selector,
        tune.limits,
        opts
      )
    end
  end

  defp selected_metric(%{scores: []}),
    do: invalid(:scores, "at least one score is required")

  defp selected_metric(%{} = tune) do
    with {:ok, selector} <- Selector.compile(tune.scores, tune.selector) do
      failure_score = Selector.failure_score(tune.scores, selector)

      metric = fn tune_case, prediction ->
        values =
          Map.new(tune.scores, fn declaration ->
            {declaration.name, score_value(declaration, tune_case, prediction)}
          end)

        with :ok <- score_errors(values) do
          normalized = Map.new(values, fn {name, {:ok, value}} -> {name, value} end)

          selected =
            normalized
            |> Map.new(fn {name, value} -> {name, value.score} end)
            |> Selector.select(tune.scores, selector)

          feedback =
            normalized
            |> Enum.map_join("; ", fn {name, value} ->
              "#{name}=#{value.score}" <> if(value.feedback, do: " (#{value.feedback})", else: "")
            end)

          %{score: selected, feedback: feedback}
        end
      end

      {:ok, metric, failure_score, selector}
    end
  end

  defp selected_metric(%{scores: []}, false), do: {:ok, nil, nil, nil}
  defp selected_metric(%{} = tune, _required?), do: selected_metric(tune)

  defp compiled_selector(%{scores: []}),
    do: invalid(:scores, "at least one score is required")

  defp compiled_selector(%{} = tune), do: Selector.compile(tune.scores, tune.selector)

  defp score_value(%Score{} = score, %Case{} = tune_case, prediction) do
    case Score.execute(score, tune_case, prediction.output, prediction) do
      {:ok, value, _metadata} -> {:ok, value}
      {:error, error, _metadata} -> {:error, error}
    end
  end

  defp score_errors(values) do
    case Enum.find(values, fn {_name, value} -> match?({:error, _}, value) end) do
      nil -> :ok
      {_name, {:error, error}} -> {:error, error}
    end
  end

  defp dataset(tune, role) do
    case Map.fetch(tune.data, role) do
      {:ok, source} when is_function(source, 0) -> source.() |> enumerable(role)
      {:ok, source} -> enumerable(source, role)
      :error -> invalid(role, "#{role} data is required")
    end
  rescue
    error -> invalid(role, "data factory failed: #{Exception.message(error)}")
  end

  defp enumerable(source, role) do
    if Enumerable.impl_for(source),
      do: {:ok, source},
      else: invalid(role, "data must implement Enumerable")
  end

  defp runtime_options(tune) do
    opts =
      []
      |> put_model_options(tune.models)
      |> put_option(:max_steps, tune.limits[:steps])
      |> put_option(:timeout, tune.limits[:deadline])

    Tune.Runtime.normalize_options(opts)
  end

  defp optimize_options(tune, optimizer, datasets, metric, failure_score, selector) do
    opts =
      [optimizer: optimizer, seed: Map.get(tune.limits, :seed, 0)]
      |> put_option(:metric, metric)
      |> put_option(:failure_score, failure_score)
      |> put_option(:scores, if(tune.scores == [], do: nil, else: tune.scores))
      |> put_option(:selector, selector)
      |> put_datasets(datasets)
      |> put_model_options(tune.models)
      |> put_option(:max_model_calls, tune.limits[:model_calls])
      |> put_option(:max_steps, tune.limits[:steps])
      |> put_option(:timeout, tune.limits[:deadline])
      |> put_option(:row_timeout, tune.limits[:row_timeout])

    {:ok, opts}
  end

  defp optimization_datasets(tune) do
    Enum.reduce_while([:train, :validation], {:ok, %{}}, fn role, {:ok, acc} ->
      if Map.has_key?(tune.data, role) do
        case optimization_dataset(tune, role) do
          {:ok, source} -> {:cont, {:ok, Map.put(acc, role, source)}}
          error -> {:halt, error}
        end
      else
        {:cont, {:ok, acc}}
      end
    end)
  end

  defp optimization_dataset(tune, :validation), do: data_factory(tune, :validation)

  defp optimization_dataset(tune, :train) do
    with {:ok, source} <- dataset(tune, :train), do: {:ok, Enum.to_list(source)}
  end

  defp put_datasets(opts, datasets) do
    opts
    |> put_option(:trainset, datasets[:train])
    |> put_option(:valset, datasets[:validation])
  end

  defp optimizer(nil), do: invalid(:search, "Tune.search/3 is required")

  defp optimizer({strategy, opts}) do
    case Tune.Search.Program.Registry.fetch(strategy) do
      nil -> invalid(:search, "unknown search strategy #{inspect(strategy)}")
      module -> {:ok, {module, opts}}
    end
  end

  defp optimizer_requirements({module, opts}) do
    with {:ok, config} <- module.init(opts) do
      requirements = module.requirements(config)
      {:ok, Map.put_new(requirements, :metric?, true)}
    end
  end

  defp genetic_strategy({:genetic, opts}), do: {:ok, opts}
  defp genetic_strategy(nil), do: invalid(:search, "Tune.search/3 is required")

  defp genetic_strategy({strategy, _opts}),
    do: invalid(:search, "#{inspect(strategy)} does not support a generic target")

  defp compile_spaces(variations) when map_size(variations) == 0,
    do: invalid(:vary, "at least one variation is required")

  defp compile_spaces(variations) do
    Enum.reduce_while(variations, {:ok, %{}}, fn {name, descriptor}, {:ok, acc} ->
      case Tune.Space.new(descriptor) do
        {:ok, space} -> {:cont, {:ok, Map.put(acc, name, space)}}
        error -> {:halt, error}
      end
    end)
  end

  defp data_factory(tune, role) do
    case Map.fetch(tune.data, role) do
      {:ok, factory} when is_function(factory, 0) -> {:ok, factory}
      {:ok, source} -> {:ok, fn -> source end}
      :error -> invalid(role, "#{role} data is required")
    end
  end

  defp describe_models(models) do
    Map.new(models, fn {role, config} ->
      {:ok, config} = ModelConfig.new(config)
      {to_string(role), ModelConfig.describe(config)}
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

  defp evaluation_runner(%{runner: nil} = tune, rows) do
    with {:ok, run_options} <- runtime_options(tune),
         {:ok, signature} <- Program.signature(tune.target),
         {:ok, target} <- Target.new(tune.target, run_options),
         {:ok, cases} <- Case.normalize_all(signature, Enum.to_list(rows)) do
      runner = fn tune_case ->
        Target.run(target, tune_case.input,
          role: :target,
          max_model_calls: Map.get(tune_case.metadata, :model_call_allowance)
        )
      end

      {:ok, cases, runner}
    end
  end

  defp evaluation_runner(%{runner: runner, target: target}, rows) do
    callback = fn tune_case -> invoke_runner(runner, target, tune_case.input) end
    {:ok, rows, callback}
  end

  defp invoke_runner(runner, target, input) when is_function(runner, 2),
    do: runner.(target, input)

  defp invoke_runner(runner, target, _input) when is_function(runner, 1), do: runner.(target)

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
