defmodule Tune do
  @moduledoc """
  Lazy evaluation and search pipelines for Elixir values and LLM programs.

  Start with `new/2`, add declarations, and end with `preview/2`, `evaluate/2`,
  or `tune/1`. Builder calls only return a new `%Tune{}` value.
  """

  alias Tune.Artifact
  alias Tune.Error
  alias Tune.ModelConfig
  alias Tune.Parameters
  alias Tune.Pipeline.Score
  alias Tune.Predictor
  alias Tune.Program
  alias Tune.Result

  @enforce_keys [:target]
  defstruct target: nil,
            runner: nil,
            data: %{},
            variations: %{},
            scores: [],
            selector: nil,
            strategy: nil,
            limits: %{},
            models: %{},
            metadata: %{}

  @type t :: %__MODULE__{
          target: term(),
          runner: function() | nil,
          data: map(),
          variations: map(),
          scores: [map()],
          selector: term(),
          strategy: term(),
          limits: map(),
          models: map(),
          metadata: map()
        }

  @new_options [:run, :model, :teacher, :proposal, :metadata]
  @data_roles [:train, :validation, :test]
  @limit_options [
    :model_calls,
    :evaluations,
    :cases,
    :concurrency,
    :row_timeout,
    :row_calls,
    :deadline,
    :steps,
    :seed
  ]

  @doc "Creates a lazy Tune pipeline."
  @spec new(term(), keyword()) :: t()
  def new(target, opts \\ []) when is_list(opts) do
    ensure_keys!(opts, @new_options, "new")
    runner = Keyword.get(opts, :run)

    if runner != nil and not is_function(runner) do
      raise ArgumentError, "the :run option must be a function"
    end

    metadata = Keyword.get(opts, :metadata, %{})

    if not is_map(metadata) do
      raise ArgumentError, "the :metadata option must be a map"
    end

    %__MODULE__{
      target: target,
      runner: runner,
      models:
        opts
        |> Keyword.take([:model, :teacher, :proposal])
        |> Map.new(),
      metadata: metadata
    }
  end

  @doc "Adds named train, validation, or test data without consuming it."
  @spec data(t(), keyword() | map()) :: t()
  def data(%__MODULE__{} = tune, data) when is_list(data) or is_map(data) do
    data = Map.new(data)
    ensure_map_keys!(data, @data_roles, "data")
    Enum.each(data, fn {role, source} -> validate_source!(role, source) end)
    %{tune | data: Map.merge(tune.data, data)}
  end

  @doc "Declares named values that a search strategy can change."
  @spec vary(t(), keyword() | map()) :: t()
  def vary(%__MODULE__{} = tune, variations) when is_list(variations) or is_map(variations) do
    variations = Map.new(variations)

    if Enum.any?(variations, fn {name, _value} -> not is_atom(name) end) do
      raise ArgumentError, "variation names must be atoms"
    end

    %{tune | variations: Map.merge(tune.variations, variations)}
  end

  @doc "Adds one uniquely named score."
  @spec score(t(), atom(), function() | module(), keyword()) :: t()
  def score(%__MODULE__{} = tune, name, metric, opts \\ [])
      when is_atom(name) and is_list(opts) do
    ensure_keys!(opts, [:direction, :range, :failure_score], "score")

    if Enum.any?(tune.scores, &(&1.name == name)) do
      raise ArgumentError, "duplicate score name #{inspect(name)}"
    end

    unless is_function(metric) or is_atom(metric) or score_extension?(metric) do
      raise ArgumentError, "a score must be a function, module, or Tune.Score struct"
    end

    direction = Keyword.get(opts, :direction, :maximize)

    if direction not in [:maximize, :minimize] do
      raise ArgumentError, "score direction must be :maximize or :minimize"
    end

    failure_score = Keyword.get(opts, :failure_score)

    if failure_score != nil and not is_number(failure_score) do
      raise ArgumentError, "score failure_score must be a number"
    end

    range = Keyword.get(opts, :range)

    if range != nil and not valid_range?(range) do
      raise ArgumentError, "score range must be {low, high} with high greater than low"
    end

    declaration = %Score{
      name: name,
      metric: metric,
      direction: direction,
      range: range,
      failure_score: failure_score
    }

    %{tune | scores: tune.scores ++ [declaration]}
  end

  @doc "Selects the score policy used to compare candidates."
  @spec select(t(), atom() | keyword()) :: t()
  def select(%__MODULE__{} = tune, name) when is_atom(name),
    do: %{tune | selector: {:score, name}}

  def select(%__MODULE__{} = tune, weighted: weights) when is_list(weights) do
    if weights == [] or
         Enum.any?(weights, fn {name, weight} ->
           not is_atom(name) or not is_number(weight) or weight <= 0
         end) do
      raise ArgumentError, "weighted selection requires score names and positive weights"
    end

    %{tune | selector: {:weighted, Map.new(weights)}}
  end

  @doc "Selects a search strategy without starting it."
  @spec search(t(), atom() | module(), keyword()) :: t()
  def search(%__MODULE__{} = tune, strategy, opts \\ [])
      when is_atom(strategy) and is_list(opts) do
    %{tune | strategy: {strategy, opts}}
  end

  @doc "Adds explicit work limits."
  @spec limit(t(), keyword() | map()) :: t()
  def limit(%__MODULE__{} = tune, limits) when is_list(limits) or is_map(limits) do
    limits = Map.new(limits)
    ensure_map_keys!(limits, @limit_options, "limit")
    Enum.each(limits, &validate_limit!/1)
    %{tune | limits: Map.merge(tune.limits, limits)}
  end

  @doc "Prepares one inspectable prompt without making a model call."
  @spec preview(t(), map() | {String.t(), map()}) ::
          {:ok, Tune.Prepared.t()} | {:error, Exception.t()}
  def preview(%__MODULE__{} = tune, input) do
    with {:ok, model} <- target_model(tune),
         {:ok, _name, predictor, inputs} <- preview_target(tune.target, input) do
      Predictor.prepare(predictor, inputs, model)
    end
  end

  @doc "Evaluates the pipeline target on test data, or on an explicit data role."
  @spec evaluate(t(), atom()) :: {:ok, Tune.Evaluation.t()} | {:error, Exception.t()}
  def evaluate(%__MODULE__{} = tune, role \\ :test) when role in @data_roles do
    with {:ok, rows} <- dataset(tune, role),
         {:ok, selector} <- compiled_selector(tune),
         {:ok, source, runner} <- evaluation_runner(tune, rows) do
      {:ok, Tune.Pipeline.Evaluator.evaluate(source, runner, tune.scores, selector, tune.limits)}
    end
  end

  @doc "Runs the selected search and returns one immutable result."
  @spec tune(t()) :: {:ok, Result.t()} | {:error, Exception.t()}
  def tune(%__MODULE__{runner: nil} = tune) do
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

  def tune(%__MODULE__{} = tune) do
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

  @doc "Builds a versioned artifact from a completed tuning result."
  @spec dump(Result.t()) :: {:ok, Artifact.t()} | {:error, Exception.t()}
  def dump(%Result{metadata: %{strategy: :genetic}} = result) do
    parameters = Map.new(result.parameters, fn {name, value} -> {to_string(name), value} end)

    with {:ok, parameters} <- portable_parameters(parameters) do
      Artifact.new(%{
        version: 1,
        target_fingerprint: contract_fingerprint(parameters),
        parameters: parameters,
        provenance: %{
          "kind" => "generic",
          "source" => "Tune.tune/1",
          "strategy" => "genetic",
          "stop_reason" => to_string(result.stop_reason),
          "complete" => result.complete?
        }
      })
    end
  end

  def dump(%Result{} = result) do
    models = Map.get(result.metadata, :models, %{})

    provenance =
      Parameters.provenance(
        source: "Tune.tune/1",
        report: result
      )
      |> Map.put("models", models)

    with {:ok, data} <- Parameters.dump(result.value, provenance: provenance) do
      parameters = Map.fetch!(data, "entries")

      Artifact.new(%{
        version: 1,
        target_fingerprint: fingerprint(parameters),
        parameters: parameters,
        provenance: Map.fetch!(data, "provenance")
      })
    end
  end

  @doc "Validates an artifact and applies it to fresh application code."
  @spec load(Artifact.t(), Program.t()) :: {:ok, Program.t()} | {:error, Exception.t()}
  def load(%Artifact{provenance: %{"kind" => "generic"}} = artifact, fresh_target)
      when is_map(fresh_target) do
    available = Map.new(fresh_target, fn {name, value} -> {to_string(name), {name, value}} end)
    names = Map.keys(artifact.parameters)
    current = Map.new(names, fn name -> {name, available[name] && elem(available[name], 1)} end)

    with :ok <- Artifact.validate(artifact),
         true <- Enum.all?(names, &Map.has_key?(available, &1)),
         true <- artifact.target_fingerprint == contract_fingerprint(current),
         {:ok, _parameters} <- portable_parameters(artifact.parameters) do
      {:ok,
       Enum.reduce(artifact.parameters, fresh_target, fn {name, value}, target ->
         {key, _old} = Map.fetch!(available, name)
         Map.put(target, key, value)
       end)}
    else
      false -> invalid(:artifact, "artifact parameters do not match the fresh target")
      error -> error
    end
  end

  def load(%Artifact{} = artifact, fresh_target) do
    data = %{
      "format" => "tune.parameters",
      "version" => artifact.version,
      "entries" => artifact.parameters,
      "provenance" => artifact.provenance
    }

    with :ok <- Artifact.validate(artifact),
         true <- artifact.target_fingerprint == fingerprint(artifact.parameters),
         {:ok, updated} <- Parameters.apply(fresh_target, data) do
      {:ok, updated}
    else
      false -> invalid(:artifact, "target fingerprint does not match the artifact parameters")
      error -> error
    end
  end

  defp selected_metric(%__MODULE__{scores: []}),
    do: invalid(:scores, "at least one score is required")

  defp selected_metric(%__MODULE__{} = tune) do
    with {:ok, selector} <- selector(tune),
         :ok <- validate_selector(selector, tune.scores) do
      failure_score = select_failures(selector, tune.scores)

      metric = fn example, prediction ->
        values =
          Map.new(tune.scores, fn declaration ->
            result = score_value(declaration, example, prediction)
            {declaration.name, result}
          end)

        with :ok <- score_errors(values) do
          normalized = Map.new(values, fn {name, {:ok, value}} -> {name, value} end)
          selected = select_score(selector, tune.scores, normalized)

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

  defp selected_metric(%__MODULE__{scores: []}, false), do: {:ok, nil, nil, nil}
  defp selected_metric(%__MODULE__{} = tune, _required?), do: selected_metric(tune)

  defp selector(%__MODULE__{scores: [%Score{name: name}], selector: nil}),
    do: {:ok, {:score, name}}

  defp selector(%__MODULE__{scores: scores, selector: nil}) when length(scores) > 1,
    do: invalid(:selector, "multiple scores require Tune.select/2")

  defp selector(%__MODULE__{selector: selector}), do: {:ok, selector}

  defp compiled_selector(%__MODULE__{scores: []}),
    do: invalid(:scores, "at least one score is required")

  defp compiled_selector(%__MODULE__{} = tune) do
    with {:ok, selector} <- selector(tune),
         :ok <- validate_selector(selector, tune.scores) do
      {:ok, selector}
    end
  end

  defp validate_selector({:score, name}, scores) do
    if Enum.any?(scores, &(&1.name == name)),
      do: :ok,
      else: elem(invalid(:selector, "unknown score #{inspect(name)}"), 1) |> then(&{:error, &1})
  end

  defp validate_selector({:weighted, weights}, scores) do
    names = MapSet.new(scores, & &1.name)
    selected = Enum.map(Map.keys(weights), &score!(scores, &1))

    if map_size(weights) > 0 and
         Enum.all?(weights, fn {name, _} -> MapSet.member?(names, name) end) and
         Enum.all?(selected, &(&1 && valid_range?(&1.range))),
       do: :ok,
       else:
         elem(
           invalid(:selector, "weighted selection requires known scores with explicit ranges"),
           1
         )
         |> then(&{:error, &1})
  end

  defp score_value(%Score{metric: metric}, example, prediction) do
    result =
      cond do
        is_function(metric, 2) ->
          metric.(example, prediction)

        is_atom(metric) and function_exported?(metric, :score, 2) ->
          metric.score(example, prediction)

        true ->
          {:error, "score callback must accept two arguments"}
      end

    Tune.Metric.normalize(result)
  rescue
    error -> {:error, error}
  end

  defp score_errors(values) do
    case Enum.find(values, fn {_name, value} -> match?({:error, _}, value) end) do
      nil -> :ok
      {_name, {:error, error}} -> {:error, error}
    end
  end

  defp select_score({:score, name}, scores, values) do
    orient(values[name].score, score!(scores, name).direction)
  end

  defp select_score({:weighted, weights}, scores, values) do
    total = weights |> Map.values() |> Enum.sum()

    Enum.sum(
      Enum.map(weights, fn {name, weight} ->
        weight * normalize_score(values[name].score, score!(scores, name))
      end)
    ) / total
  end

  defp select_failures({:score, name}, scores) do
    score = score!(scores, name)
    if is_number(score.failure_score), do: orient(score.failure_score, score.direction)
  end

  defp select_failures({:weighted, weights}, scores) do
    if Enum.all?(weights, fn {name, _} -> is_number(score!(scores, name).failure_score) end) do
      total = weights |> Map.values() |> Enum.sum()

      Enum.sum(
        Enum.map(weights, fn {name, weight} ->
          score = score!(scores, name)
          normalize_score(score.failure_score, score) * weight
        end)
      ) / total
    end
  end

  defp normalize_score(value, %Score{range: {low, high}, direction: direction}) do
    normalized = (value - low) / (high - low)
    if direction == :maximize, do: normalized, else: 1.0 - normalized
  end

  defp orient(value, :maximize), do: value
  defp orient(value, :minimize), do: -value

  defp valid_range?({low, high}), do: is_number(low) and is_number(high) and high > low
  defp valid_range?(_range), do: false

  defp score!(scores, name), do: Enum.find(scores, &(&1.name == name))

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
      [
        optimizer: optimizer,
        seed: Map.get(tune.limits, :seed, 0)
      ]
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
        case dataset(tune, role) do
          {:ok, source} -> {:cont, {:ok, Map.put(acc, role, Enum.to_list(source))}}
          error -> {:halt, error}
        end
      else
        {:cont, {:ok, acc}}
      end
    end)
  end

  defp put_datasets(opts, datasets) do
    opts
    |> put_option(:trainset, datasets[:train])
    |> put_option(:valset, datasets[:validation])
  end

  defp optimizer(nil), do: invalid(:search, "Tune.search/3 is required")

  defp optimizer({strategy, opts}) do
    case optimizer_module(strategy) do
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

  defp optimizer_module(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :compile, 3) do
      module
    else
      Map.get(optimizer_modules(), module)
    end
  end

  defp optimizer_modules do
    %{
      labeled_few_shot: Tune.Optimizers.LabeledFewShot,
      bootstrap_few_shot: Tune.Optimizers.BootstrapFewShot,
      bootstrap_few_shot_random_search: Tune.Optimizers.BootstrapFewShotWithRandomSearch,
      bootstrap_few_shot_optuna: Tune.Optimizers.BootstrapFewShotWithOptuna,
      knn_few_shot: Tune.Optimizers.KNNFewShot,
      copro: Tune.Optimizers.COPRO,
      signature_optimizer: Tune.Optimizers.SignatureOptimizer,
      mipro_v2: Tune.Optimizers.MIPROv2,
      infer_rules: Tune.Optimizers.InferRules,
      simba: Tune.Optimizers.SIMBA,
      gepa: Tune.Optimizers.GEPA,
      avatar: Tune.Optimizers.Avatar,
      playbook: Tune.Optimizers.Playbook,
      anything: Tune.Optimizers.Anything,
      ensemble: Tune.Optimizers.Ensemble
    }
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

  defp require_program_target(%__MODULE__{runner: nil, target: target}) do
    with {:ok, _} <- Program.parameters(target), do: :ok
  end

  defp require_program_target(%__MODULE__{}),
    do: invalid(:target, "generic runners are implemented in the generic-search unit")

  defp evaluation_runner(%__MODULE__{runner: nil} = tune, rows) do
    with {:ok, run_options} <- runtime_options(tune),
         {:ok, signature} <- Program.signature(tune.target),
         {:ok, _parameters} <- Program.parameters(tune.target),
         {:ok, examples} <- Tune.Example.normalize_all(signature, Enum.to_list(rows)) do
      runner = fn tune_case ->
        allowance = Map.get(tune_case.metadata, :model_call_allowance)
        options = put_option(run_options, :max_model_calls, allowance)

        with {:ok, execution} <- Tune.Runtime.new_execution(tune.target, options) do
          case Tune.Runtime.run_with(tune.target, tune_case.input, execution) do
            {:ok, prediction} ->
              {:ok, prediction.output, prediction}

            {:error, %Error.Execution.Failed{result: prediction} = error} ->
              {:error, error, prediction}

            {:error, error} ->
              {:error, error}
          end
        end
      end

      {:ok, examples, runner}
    end
  end

  defp evaluation_runner(%__MODULE__{runner: runner, target: target}, rows) do
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

  defp fingerprint(parameters) do
    parameters
    |> Tune.Example.canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp portable_parameters(parameters) do
    case Zoi.parse(Zoi.map(Zoi.string(), Zoi.json()), parameters) do
      {:ok, parameters} ->
        {:ok, parameters}

      {:error, _errors} ->
        invalid(:artifact, "learned parameters must contain only JSON-compatible values")
    end
  end

  defp contract_fingerprint(value) do
    value
    |> value_contract()
    |> Tune.Example.canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp value_contract(value) when is_integer(value), do: "integer"
  defp value_contract(value) when is_float(value), do: "float"
  defp value_contract(value) when is_binary(value), do: "string"
  defp value_contract(value) when is_boolean(value), do: "boolean"
  defp value_contract(nil), do: "null"

  defp value_contract(value) when is_list(value) do
    %{"list" => value |> Enum.map(&value_contract/1) |> Enum.uniq() |> Enum.sort()}
  end

  defp value_contract(value) when is_map(value) and not is_struct(value) do
    %{"map" => Map.new(value, fn {key, item} -> {to_string(key), value_contract(item)} end)}
  end

  defp value_contract(_value), do: "unsupported"

  defp validate_source!(_role, source) when is_function(source, 0), do: :ok

  defp validate_source!(role, source) do
    if is_nil(Enumerable.impl_for(source)) do
      raise ArgumentError, "#{role} data must implement Enumerable or be a zero-arity function"
    end
  end

  defp score_extension?(%module{}) do
    Code.ensure_loaded?(module) and function_exported?(module, :score, 3)
  end

  defp score_extension?(_metric), do: false

  defp require_score_call_limit(%__MODULE__{} = tune) do
    calls_models? =
      Enum.any?(tune.scores, fn %{metric: metric} ->
        is_struct(metric) and
          function_exported?(metric.__struct__, :model_calls?, 1) and
          metric.__struct__.model_calls?(metric)
      end)

    if calls_models? and not is_integer(tune.limits[:model_calls]),
      do:
        elem(invalid(:model_calls, "an explicit model call limit is required"), 1)
        |> then(&{:error, &1}),
      else: :ok
  end

  defp validate_limit!({key, value}) when key in [:model_calls, :evaluations, :cases, :steps] do
    if not (is_integer(value) and value >= 0) do
      raise ArgumentError, "#{key} must be a nonnegative integer"
    end
  end

  defp validate_limit!({key, value}) when key in [:concurrency, :row_timeout, :row_calls] do
    if not (is_integer(value) and value > 0) do
      raise ArgumentError, "#{key} must be a positive integer"
    end
  end

  defp validate_limit!({:deadline, :infinity}), do: :ok

  defp validate_limit!({:deadline, value}) when is_integer(value) and value >= 0, do: :ok
  defp validate_limit!({:seed, value}) when is_integer(value), do: :ok
  defp validate_limit!({key, _value}), do: raise(ArgumentError, "invalid #{key} limit")

  defp ensure_keys!(opts, allowed, name), do: ensure_map_keys!(Map.new(opts), allowed, name)

  defp ensure_map_keys!(map, allowed, name) do
    case Map.keys(map) -- allowed do
      [] -> :ok
      [key | _] -> raise ArgumentError, "unknown #{name} option #{inspect(key)}"
    end
  end

  defp invalid(option, message),
    do: {:error, Error.Invalid.Option.exception(option: option, message: message)}
end
