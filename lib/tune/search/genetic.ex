defmodule Tune.Search.Genetic do
  @moduledoc false

  alias Tune.Error
  alias Tune.Evaluation
  alias Tune.Input
  alias Tune.Observation
  alias Tune.Result
  alias Tune.Score
  alias Tune.Search.Generic
  alias Tune.Search.Study
  alias Tune.Space

  @rate Zoi.number() |> Zoi.gte(0) |> Zoi.lte(1)
  @options Zoi.keyword(
             [
               population_size: Zoi.integer() |> Zoi.positive(),
               generations: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(20),
               mutation_rate: @rate |> Zoi.default(0.1),
               crossover_rate: @rate |> Zoi.default(0.8),
               elitism: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(1),
               tournament_size: Zoi.integer() |> Zoi.positive() |> Zoi.default(3),
               cancel: Zoi.function(arity: 0) |> Zoi.nullable() |> Zoi.default(nil),
               initial_population:
                 Zoi.array(Zoi.any()) |> Zoi.min(1) |> Zoi.nullable() |> Zoi.default(nil),
               mutate: Zoi.function(arity: 2) |> Zoi.nullable() |> Zoi.default(nil),
               crossover: Zoi.function(arity: 3) |> Zoi.nullable() |> Zoi.default(nil),
               valid?: Zoi.function(arity: 1) |> Zoi.nullable() |> Zoi.default(nil),
               select_parent: Zoi.function(arity: 2) |> Zoi.nullable() |> Zoi.default(nil),
               target_score: Zoi.number() |> Zoi.nullable() |> Zoi.default(nil),
               patience: Zoi.integer() |> Zoi.positive() |> Zoi.nullable() |> Zoi.default(nil),
               candidate_concurrency: Zoi.integer() |> Zoi.positive() |> Zoi.default(1)
             ],
             unrecognized_keys: :error
           )

  @spec run(term(), function(), (-> Enumerable.t()), map(), list(), term(), map(), keyword()) ::
          {:ok, Result.t()} | {:error, Exception.t()}
  def run(target, runner, data_factory, spaces, scores, selector, limits, opts) do
    with {:ok, config} <- config(opts),
         :ok <- evaluation_limit(limits),
         :ok <- check_candidate_concurrency(config, limits, scores),
         :ok <- validate_operators(spaces, config),
         :ok <- validate_population(target, spaces, config, limits) do
      limits = Map.put(limits, :cancel, config.cancel || limits[:cancel])

      study =
        Study.new(
          seed: Map.get(limits, :seed, 0),
          limits: limits,
          metadata: %{strategy: :genetic}
        )

      {cases, study} = Generic.snapshot(data_factory, study)

      state = %{
        study: study,
        config: config,
        target: target,
        runner: runner,
        cases: cases,
        spaces: spaces,
        scores: scores,
        selector: selector,
        baseline: nil,
        last_improvement: 0,
        generation: 0
      }

      state |> search() |> result()
    end
  end

  defp search(state) do
    case Study.limit_reason(state.study) do
      nil ->
        {requests, state} = initial_population(state)
        {population, state} = evaluate_population(requests, state)

        baseline =
          if state.config.initial_population == nil and population != [],
            do: hd(population).evaluation

        finish_generation(%{state | baseline: baseline}, population, length(requests), nil)

      reason ->
        stop(state, reason)
    end
  end

  defp initial_population(%{config: %{initial_population: seeds}} = state) when is_list(seeds) do
    requests =
      Enum.map(seeds, fn value ->
        {parameters(value, state.spaces), %{kind: :initial, generation: 0}}
      end)

    {requests, state}
  end

  defp initial_population(state) do
    count = min(state.config.population_size, Study.remaining_evaluations(state.study))
    baseline = {parameters(state.target, state.spaces), %{kind: :baseline, generation: 0}}

    {sampled, state} =
      Enum.map_reduce(2..count//1, state, fn _, state ->
        {params, state} = sample_parameters(state)
        {{params, %{kind: :initial, generation: 0}}, state}
      end)

    {[baseline | sampled], state}
  end

  defp finish_generation(state, population, count, previous_best) do
    complete? = length(population) == count and Study.stop_reason(state.study) == nil

    study =
      if not complete? and previous_best,
        do: %{state.study | best: previous_best},
        else: state.study

    best = Study.incumbent(study)
    improved? = best && (previous_best == nil or best.id != previous_best.id)
    state = %{state | study: study}
    state = if improved?, do: %{state | last_improvement: state.generation}, else: state

    Study.emit(state.study, %{
      event: :generation_evaluated,
      generation: state.generation,
      population: population,
      complete?: complete?,
      best: best
    })

    cond do
      Study.stop_reason(state.study) ->
        state

      best && reached_target?(state, best) ->
        stop(state, :target_score)

      state.config.patience && state.generation - state.last_improvement >= state.config.patience ->
        stop(state, :patience)

      state.generation >= state.config.generations ->
        stop(state, :completed)

      Study.remaining_evaluations(state.study) < state.config.population_size ->
        stop(state, :evaluation_limit)

      Enum.all?(population, &(not &1.evaluation.eligible?)) ->
        stop(state, :no_eligible_parent)

      true ->
        generation = state.generation + 1
        {requests, state} = next_generation(population, generation, state)
        {population, state} = evaluate_population(requests, %{state | generation: generation})
        finish_generation(state, population, length(requests), best)
    end
  end

  defp evaluate_population(requests, state) do
    requests
    |> Stream.chunk_every(state.config.candidate_concurrency)
    |> Enum.reduce_while({[], state}, fn batch, {acc, state} ->
      case Study.limit_reason(state.study) do
        nil ->
          {candidates, state} = evaluate_batch(batch, state)

          if Study.stop_reason(state.study),
            do: {:halt, {Enum.reverse(candidates, acc), state}},
            else: {:cont, {Enum.reverse(candidates, acc), state}}

        reason ->
          {:halt, {acc, stop(state, reason)}}
      end
    end)
    |> then(fn {population, state} -> {Enum.reverse(population), state} end)
  end

  defp evaluate_batch([request], state) do
    {candidate, state} = record(evaluate(request, state), state)
    {[candidate], state}
  end

  defp evaluate_batch(requests, state) do
    requests
    |> Task.async_stream(&evaluate(&1, state),
      max_concurrency: length(requests),
      timeout: :infinity
    )
    |> Enum.map_reduce(state, fn {:ok, evaluation}, state -> record(evaluation, state) end)
  end

  defp reached_target?(%{config: %{target_score: nil}}, _best), do: false

  defp reached_target?(%{config: config, selector: selector, scores: scores}, best) do
    threshold =
      case selector do
        {:score, name} ->
          Tune.Score.Selector.select(%{name => config.target_score}, scores, selector)

        {:weighted, _} ->
          config.target_score
      end

    best.evaluation.selected_score >= threshold
  end

  defp next_generation(population, generation, state) do
    eligible = Enum.filter(population, & &1.evaluation.eligible?)

    elites =
      eligible
      |> Enum.sort_by(& &1.evaluation.selected_score, :desc)
      |> Enum.take(state.config.elitism)
      |> Enum.map(&{&1.parameters, %{kind: :elite, generation: generation, parents: [&1.id]}})

    needed = state.config.population_size - length(elites)

    Enum.map_reduce(1..needed//1, state, fn _, state ->
      {left, state} = tournament(eligible, state)
      {right, state} = tournament(eligible, state)
      {params, state} = reproduce(left.parameters, right.parameters, state)

      {{params, %{kind: :offspring, generation: generation, parents: [left.id, right.id]}}, state}
    end)
    |> then(fn {children, state} -> {elites ++ children, state} end)
  end

  defp reproduce(%{genome: left}, %{genome: right}, %{spaces: spaces} = state)
       when map_size(spaces) == 0 do
    {cross, state} = random(state, &Space.uniform/1)
    {mutate, state} = random(state, &Space.uniform/1)

    {value, state} =
      if state.config.crossover && cross < state.config.crossover_rate,
        do: random(state, &state.config.crossover.(left, right, &1)),
        else: {left, state}

    {value, state} =
      if state.config.mutate && mutate < state.config.mutation_rate,
        do: random(state, &state.config.mutate.(value, &1)),
        else: {value, state}

    {%{genome: value}, state}
  end

  defp reproduce(left, right, state) do
    Enum.reduce(state.spaces, {%{}, state}, fn {name, space}, {params, state} ->
      {unit, state} = random(state, &Space.uniform/1)

      {value, state} =
        if unit < state.config.crossover_rate do
          random(state, &Space.crossover(space, left[name], right[name], &1))
        else
          {left[name], state}
        end

      {unit, state} = random(state, &Space.uniform/1)

      {value, state} =
        if unit < state.config.mutation_rate do
          random(state, &Space.mutate(space, value, &1))
        else
          {value, state}
        end

      {Map.put(params, name, value), state}
    end)
  end

  defp tournament(population, %{config: %{select_parent: select}} = state)
       when is_function(select) do
    {selected_id, state} = random(state, &select.(population, &1))

    case Enum.find(population, &(&1.id == selected_id)) do
      nil ->
        raise Error.Invalid.Option.exception(
                option: :select_parent,
                message: "select_parent must return an eligible candidate ID"
              )

      candidate ->
        {candidate, state}
    end
  end

  defp tournament(population, state) do
    count = min(state.config.tournament_size, length(population))

    {sample, state} =
      Enum.map_reduce(1..count//1, state, fn _, state ->
        {index, state} = random(state, &Space.integer(&1, length(population)))
        {Enum.at(population, index), state}
      end)

    {Enum.max_by(sample, & &1.evaluation.selected_score), state}
  end

  defp sample_parameters(state) do
    Enum.reduce(state.spaces, {%{}, state}, fn {name, space}, {params, state} ->
      {value, state} = random(state, &Space.sample(space, &1))
      {Map.put(params, name, value), state}
    end)
  end

  defp evaluate({params, lineage}, state) do
    value = apply_parameters(state.target, params, state.spaces)
    limits = Study.evaluation_limits(state.study)

    limits =
      if state.config.candidate_concurrency > 1,
        do: Map.delete(limits, :on_progress),
        else: limits

    evaluation =
      if valid_candidate?(value, state.spaces, state.config) do
        Generic.evaluate(state.cases, state.runner, value, state.scores, state.selector, limits)
      else
        error =
          Error.Invalid.Option.exception(
            option: :genetic,
            message: "variation produced an invalid candidate"
          )

        %Evaluation{
          complete?: true,
          observations: [%Observation{status: :error, eligible?: false, error: error}]
        }
      end

    {value, params, lineage, evaluation}
  end

  defp record({value, params, lineage, evaluation}, state) do
    {candidate, study} = Generic.record(state.study, value, params, evaluation, lineage)
    {candidate, %{state | study: study}}
  end

  defp result(state) do
    reason = Study.stop_reason(state.study) || :completed
    best = Study.incumbent(state.study)

    Generic.result(state.study,
      baseline: state.baseline,
      stop_reason: reason,
      complete?: reason in [:completed, :target_score, :patience],
      metadata:
        if(best,
          do: %{
            settings: settings(state.config),
            genome?: state.spaces == %{},
            seed: state.study.seed
          },
          else: %{settings: settings(state.config)}
        )
    )
  end

  defp parameters(target, spaces) when map_size(spaces) == 0, do: %{genome: target}

  defp parameters(target, spaces),
    do: Map.new(spaces, fn {name, _} -> {name, Map.fetch!(target, name)} end)

  defp apply_parameters(_target, %{genome: value}, spaces) when map_size(spaces) == 0, do: value

  defp apply_parameters(target, params, _spaces),
    do: Generic.apply_parameters(target, params)

  defp validate_population(target, spaces, config, limits) do
    seeds = config.initial_population || [target]

    cond do
      config.initial_population && config.population_size > limits.evaluations ->
        invalid("the evaluation limit must cover the initial population")

      config.initial_population && spaces != %{} &&
          Enum.any?(seeds, &(fixed_fields(&1, spaces) != fixed_fields(target, spaces))) ->
        invalid("seed candidates must match the target outside declared variations")

      Enum.all?(seeds, &valid_candidate?(&1, spaces, config)) ->
        :ok

      true ->
        invalid(
          "the initial population contains a value outside the declared spaces or validity contract"
        )
    end
  end

  defp fixed_fields(value, spaces) when is_map(value), do: Map.drop(value, Map.keys(spaces))
  defp fixed_fields(value, _spaces), do: value

  defp valid_candidate?(target, spaces, config) when map_size(spaces) == 0,
    do: config.valid? == nil or config.valid?.(target)

  defp valid_candidate?(target, spaces, _config) when is_map(target) do
    Enum.all?(spaces, fn {name, space} ->
      case Map.fetch(target, name) do
        {:ok, value} -> Space.valid?(space, value)
        :error -> false
      end
    end)
  end

  defp valid_candidate?(_target, _spaces, _config), do: false

  defp validate_operators(spaces, config) do
    if spaces != %{} and (config.mutate || config.crossover || config.valid?),
      do: invalid("genome operators require an initial population without named variations"),
      else: :ok
  end

  defp check_candidate_concurrency(config, limits, scores) do
    if config.candidate_concurrency > 1 and
         (limits[:model_calls] != nil or Enum.any?(scores, &Score.model_calls?/1)),
       do: invalid("parallel candidate evaluation requires a study without managed model calls"),
       else: :ok
  end

  defp settings(config),
    do:
      Map.drop(config, [
        :cancel,
        :initial_population,
        :mutate,
        :crossover,
        :valid?,
        :select_parent
      ])

  defp config(opts) do
    case Input.options(@options, opts, :genetic) do
      {:ok, parsed} ->
        size = if parsed[:initial_population], do: length(parsed[:initial_population]), else: 20
        config = parsed |> Map.new() |> Map.put_new(:population_size, size)
        validate_config(config)

      {:error, error} ->
        invalid(Exception.message(error))
    end
  end

  defp validate_config(config) do
    cond do
      config.elitism > config.population_size ->
        invalid("elitism must be between zero and population_size")

      config.initial_population && length(config.initial_population) != config.population_size ->
        invalid("initial_population must contain exactly population_size candidates")

      true ->
        {:ok, config}
    end
  end

  defp evaluation_limit(limits) do
    case Map.get(limits, :evaluations) do
      value when is_integer(value) and value > 0 -> :ok
      _ -> invalid("an explicit positive evaluation limit is required")
    end
  end

  defp random(state, operation) do
    {value, study} = Study.random(state.study, operation)
    {value, %{state | study: study}}
  end

  defp stop(state, reason), do: %{state | study: Study.stop(state.study, reason)}

  defp invalid(message),
    do: {:error, Error.Invalid.Option.exception(option: :genetic, message: message)}
end
