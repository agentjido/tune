defmodule Tune.Search.Genetic do
  @moduledoc false

  alias Tune.Candidate
  alias Tune.Error
  alias Tune.Pipeline.Evaluator
  alias Tune.Result
  alias Tune.Search.Context
  alias Tune.Space

  @options [
    :population_size,
    :generations,
    :mutation_rate,
    :crossover_rate,
    :elitism,
    :tournament_size,
    :cancel
  ]

  @defaults %{
    population_size: 20,
    generations: 20,
    mutation_rate: 0.1,
    crossover_rate: 0.8,
    elitism: 1,
    tournament_size: 3,
    cancel: nil
  }

  @spec run(term(), function(), (-> Enumerable.t()), map(), list(), term(), map(), keyword()) ::
          {:ok, Result.t()} | {:error, Exception.t()}
  def run(target, runner, data_factory, spaces, scores, selector, limits, opts) do
    with {:ok, config} <- config(opts),
         {:ok, max_evaluations} <- evaluation_limit(limits),
         :ok <- validate_target(target, spaces) do
      context =
        Context.new(
          optimizer: __MODULE__,
          run_options: [],
          seed: Map.get(limits, :seed, 0),
          target: target,
          data: %{validation: data_factory},
          scores: scores,
          selector: selector,
          limits: limits,
          max_model_calls: Map.get(limits, :model_calls),
          metadata: %{strategy: :genetic}
        )

      state = %{
        context: context,
        config: config,
        target: target,
        runner: runner,
        data_factory: data_factory,
        spaces: spaces,
        scores: scores,
        selector: selector,
        limits: limits,
        max_evaluations: max_evaluations,
        evaluations: 0,
        random: :rand.seed_s(:exsss, Map.get(limits, :seed, 0)),
        baseline: nil,
        started_at: System.monotonic_time(:millisecond),
        stop_reason: nil
      }

      case search(state) do
        %{context: %{best: %Candidate{}}} = state -> {:ok, result(state)}
        state -> no_candidate(state)
      end
    end
  end

  defp search(state) do
    count = min(state.config.population_size, state.max_evaluations)
    {population, state} = initial_population(state, count)
    state = %{state | baseline: population |> List.first() |> then(&(&1 && &1.evaluation))}

    if state.stop_reason do
      state
    else
      generations(state, population, 1)
    end
  end

  defp initial_population(state, count) do
    params = parameters(state.target, state.spaces)
    {baseline, state} = evaluate(params, %{kind: :baseline}, state)

    Enum.map_reduce(2..count//1, state, fn _, state ->
      {params, state} = sample_parameters(state)
      evaluate(params, %{kind: :initial}, state)
    end)
    |> then(fn {sampled, state} -> {[baseline | sampled], state} end)
  end

  defp generations(state, _population, generation)
       when generation > state.config.generations,
       do: %{state | stop_reason: :completed}

  defp generations(state, population, generation) do
    cond do
      cancelled?(state) ->
        %{state | stop_reason: :cancelled}

      deadline?(state) ->
        %{state | stop_reason: :deadline}

      Context.exhausted?(state.context) ->
        %{state | stop_reason: :model_call_limit}

      state.max_evaluations - state.evaluations < state.config.population_size ->
        %{state | stop_reason: :evaluation_limit}

      Enum.all?(population, &(not &1.evaluation.eligible?)) ->
        %{state | stop_reason: :no_eligible_parent}

      true ->
        {requests, state} = next_generation(population, generation, state)

        {population, state} =
          Enum.map_reduce(requests, state, fn {params, lineage}, state ->
            evaluate(params, lineage, state)
          end)

        generations(state, population, generation + 1)
    end
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

  defp reproduce(left, right, state) do
    Enum.reduce(state.spaces, {%{}, state}, fn {name, space}, {params, state} ->
      {unit, random} = Space.uniform(state.random)
      state = %{state | random: random}

      {value, state} =
        if unit < state.config.crossover_rate do
          {value, random} = Space.crossover(space, left[name], right[name], state.random)
          {value, %{state | random: random}}
        else
          {left[name], state}
        end

      {unit, random} = Space.uniform(state.random)
      state = %{state | random: random}

      {value, state} =
        if unit < state.config.mutation_rate do
          {value, random} = Space.mutate(space, value, state.random)
          {value, %{state | random: random}}
        else
          {value, state}
        end

      {Map.put(params, name, value), state}
    end)
  end

  defp tournament(population, state) do
    count = min(state.config.tournament_size, length(population))

    {sample, state} =
      Enum.map_reduce(1..count//1, state, fn _, state ->
        {index, random} = Space.integer(state.random, length(population))
        {Enum.at(population, index), %{state | random: random}}
      end)

    {Enum.max_by(sample, & &1.evaluation.selected_score), state}
  end

  defp sample_parameters(state) do
    Enum.reduce(state.spaces, {%{}, state}, fn {name, space}, {params, state} ->
      {value, random} = Space.sample(space, state.random)
      {Map.put(params, name, value), %{state | random: random}}
    end)
  end

  defp evaluate(params, lineage, state) do
    value = apply_parameters(state.target, params)

    callback = fn tune_case -> invoke(state.runner, value, tune_case.input) end

    limits = Map.put(state.limits, :model_calls, state.context.budget)

    evaluation =
      Evaluator.evaluate(
        state.data_factory.(),
        callback,
        state.scores,
        state.selector,
        Map.delete(limits, :evaluations)
      )

    candidate = %Candidate{
      id: Integer.to_string(state.context.next_id),
      parameters: params,
      value: value,
      evaluation: evaluation,
      lineage: lineage
    }

    context =
      state.context
      |> Context.account_evaluation(evaluation)
      |> Context.record(candidate)

    state = %{state | context: context, evaluations: state.evaluations + 1}

    {candidate, state}
  end

  defp invoke(runner, target, input) when is_function(runner, 2), do: runner.(target, input)
  defp invoke(runner, target, _input) when is_function(runner, 1), do: runner.(target)

  defp result(state) do
    best = state.context.best

    Context.result(state.context, best.value, best.parameters,
      baseline: state.baseline,
      stop_reason: state.stop_reason || :completed,
      complete?: state.stop_reason == :completed,
      metadata: %{
        strategy: :genetic,
        evaluations: state.evaluations,
        settings: Map.delete(state.config, :cancel)
      }
    )
  end

  defp no_candidate(state) do
    report =
      Context.result(state.context, nil, %{},
        baseline: state.baseline,
        stop_reason: state.stop_reason || :no_eligible_candidate,
        complete?: false,
        metadata: %{
          strategy: :genetic,
          evaluations: state.evaluations,
          settings: Map.delete(state.config, :cancel)
        }
      )

    {:error,
     Error.Optimization.Failed.exception(
       message: "no candidate completed an eligible evaluation",
       report: report
     )}
  end

  defp parameters(target, spaces),
    do: Map.new(spaces, fn {name, _} -> {name, Map.fetch!(target, name)} end)

  defp apply_parameters(target, params),
    do: Enum.reduce(params, target, fn {k, v}, acc -> Map.put(acc, k, v) end)

  defp validate_target(target, spaces) when is_map(target) do
    Enum.reduce_while(spaces, :ok, fn {name, space}, :ok ->
      case Map.fetch(target, name) do
        {:ok, value} ->
          if Space.valid?(space, value),
            do: {:cont, :ok},
            else: {:halt, invalid("initial value #{inspect(name)} is outside its space")}

        :error ->
          {:halt, invalid("target has no value named #{inspect(name)}")}
      end
    end)
  end

  defp validate_target(_target, _spaces),
    do: invalid("genetic search requires a map or struct target")

  defp config(opts) do
    unknown = Keyword.keys(opts) -- @options
    config = Map.merge(@defaults, Map.new(opts))

    cond do
      unknown != [] ->
        invalid("unknown genetic option #{inspect(hd(unknown))}")

      not positive?(config.population_size) ->
        invalid("population_size must be positive")

      not non_negative?(config.generations) ->
        invalid("generations must be nonnegative")

      not rate?(config.mutation_rate) ->
        invalid("mutation_rate must be between 0 and 1")

      not rate?(config.crossover_rate) ->
        invalid("crossover_rate must be between 0 and 1")

      not non_negative?(config.elitism) or config.elitism > config.population_size ->
        invalid("elitism must be between zero and population_size")

      not positive?(config.tournament_size) ->
        invalid("tournament_size must be positive")

      config.cancel != nil and not is_function(config.cancel, 0) ->
        invalid("cancel must be a zero-arity function")

      true ->
        {:ok, config}
    end
  end

  defp evaluation_limit(limits) do
    case Map.get(limits, :evaluations) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> invalid("an explicit positive evaluation limit is required")
    end
  end

  defp cancelled?(%{config: %{cancel: nil}}), do: false
  defp cancelled?(%{config: %{cancel: cancel}}), do: cancel.()

  defp deadline?(%{limits: %{deadline: :infinity}}), do: false

  defp deadline?(%{limits: %{deadline: deadline}, started_at: started_at})
       when is_integer(deadline) do
    System.monotonic_time(:millisecond) - started_at >= deadline
  end

  defp deadline?(_state), do: false

  defp positive?(value), do: is_integer(value) and value > 0
  defp non_negative?(value), do: is_integer(value) and value >= 0
  defp rate?(value), do: is_number(value) and value >= 0 and value <= 1

  defp invalid(message),
    do: {:error, Error.Invalid.Option.exception(option: :genetic, message: message)}
end
