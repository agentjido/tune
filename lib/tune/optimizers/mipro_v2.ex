defmodule Tune.Optimizers.MIPROv2 do
  @moduledoc """
  Joint search over instructions and example sets.

  1. Example sets: per predictor, `num_candidates` choices: no demonstrations,
     then bootstrapped sets from the teacher role.
  2. Instructions: per predictor, the original instruction plus
     `num_candidates - 1` proposals from the proposal role, grounded in the
     predictor's fields, training examples, and a bootstrapped demonstration.
  3. Search: a categorical TPE over `<name>.instruction` and `<name>.demos`.
     Each trial scores a training minibatch; minibatch observations guide the
     sampler but never become the returned program. Every
     `minibatch_full_eval_steps` trials, and at the end, the best unpromoted
     choice by mean minibatch score gets a full validation pass. Only full,
     complete, eligible validation results can become the incumbent.

  The baseline (original instructions, no demonstrations) is evaluated on the
  full validation set first. Teacher, proposal, and target calls share one
  ceiling.

  Options: `:num_candidates` (default 4), `:num_trials` (default 12),
  `:minibatch_size` (default 4), `:minibatch_full_eval_steps` (default 4),
  `:n_startup` (default 4), `:evidence_examples` (default 3), and
  BootstrapFewShot options (`:accept_score` required).

  Differences from DSPy: minibatches come from training data; there is no
  automatic configuration preset, dataset summarizer, or program-code
  summary; proposals are grounded in the signature and examples.
  """

  @behaviour Tune.Search.ProgramStrategy

  alias Tune.Optimizers.BootstrapFewShot
  alias Tune.Optimizers.BootstrapFewShotWithRandomSearch
  alias Tune.Optimizers.ExampleSets
  alias Tune.Optimizers.Proposals
  alias Tune.Optimizers.Shared
  alias Tune.Optimizers.TPE
  alias Tune.Search.Program.Context

  @fields [
    num_candidates: Zoi.integer() |> Zoi.positive() |> Zoi.default(4),
    num_trials: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(12),
    minibatch_size: Zoi.integer() |> Zoi.positive() |> Zoi.default(4),
    minibatch_full_eval_steps: Zoi.integer() |> Zoi.positive() |> Zoi.default(4),
    n_startup: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(4),
    evidence_examples: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(3)
  ]
  @options Zoi.keyword(@fields, unrecognized_keys: :error)

  @impl true
  def init(opts) do
    {own, boot} = Keyword.split(opts, Keyword.keys(@fields))

    with {:ok, own} <- Shared.options(@options, own),
         {:ok, boot} <- BootstrapFewShot.init(boot),
         :ok <- BootstrapFewShotWithRandomSearch.require_accept(boot) do
      {:ok, Map.merge(boot, own)}
    end
  end

  @impl true
  def requirements(_config),
    do: %{datasets: [:train, :validation], roles: [:teacher, :proposal], model_calls?: true}

  @impl true
  def compile(config, program, %Context{} = ctx) do
    names = Enum.map(Shared.predictors(program), &elem(&1, 0))
    {baseline, ctx} = Context.evaluate_validation(ctx, program)
    {_id, ctx} = Context.consider(ctx, program, baseline, %{label: "baseline"})

    {boot_sets, ctx} =
      ExampleSets.bootstrap_sets(config, program, ctx, max(config.num_candidates - 1, 0))

    demo_sets = [Map.new(names, &{&1, []}) | Enum.map(boot_sets, &demos_of/1)]
    {instructions, ctx} = propose_instructions(config, program, names, boot_sets, ctx)

    space =
      Enum.flat_map(names, fn name ->
        [
          {"#{name}.instruction", length(instructions[name])},
          {"#{name}.demos", length(demo_sets)}
        ]
      end)
      |> Map.new()

    ctx = Context.note(ctx, :space, space)
    tpe = TPE.new(space, n_startup: config.n_startup)
    default = Map.new(space, fn {key, _n} -> {key, 0} end)

    state = %{observations: [], minibatch: %{}, promoted: MapSet.new([default]), trials: []}
    build = fn choice -> candidate(program, names, instructions, demo_sets, choice) end
    {state, ctx} = trials(config, tpe, build, state, ctx, 1)
    {state, ctx} = promote(build, state, ctx)

    ctx =
      ctx
      |> Context.note(:trials, Enum.reverse(state.trials))
      |> Context.note(:instructions, instructions)

    ctx = if Context.exhausted?(ctx), do: Context.stop(ctx, :budget_exhausted), else: ctx
    Context.best(ctx)
  end

  defp demos_of(candidate),
    do: Map.new(Shared.predictors(candidate), fn {name, p} -> {name, p.demos} end)

  defp propose_instructions(config, program, names, boot_sets, ctx) do
    predictors = Map.new(Shared.predictors(program))

    Enum.reduce(names, {%{}, ctx}, fn name, {acc, ctx} ->
      predictor = Map.fetch!(predictors, name)
      original = predictor.signature.instructions

      {proposed, ctx} =
        if config.num_candidates > 1 and not Context.exhausted?(ctx) do
          Proposals.instructions(ctx, predictor,
            n: config.num_candidates - 1,
            evidence: grounding(config, name, boot_sets, ctx)
          )
        else
          {[], ctx}
        end

      {Map.put(acc, name, Enum.uniq([original | proposed])), ctx}
    end)
  end

  defp grounding(config, name, boot_sets, ctx) do
    demo =
      Enum.find_value(boot_sets, fn candidate ->
        case Map.new(Shared.predictors(candidate)) |> Map.fetch!(name) do
          %{demos: [demo | _]} -> "Example trace:\n" <> Shared.render_step(demo)
          _ -> nil
        end
      end)

    Enum.join(
      Enum.reject([Proposals.evidence(ctx.train, config.evidence_examples), demo], &is_nil/1),
      "\n\n"
    )
  end

  defp candidate(program, names, instructions, demo_sets, choice) do
    {:ok, candidate} =
      Shared.put_instructions(
        program,
        Map.new(names, &{&1, Enum.at(instructions[&1], choice["#{&1}.instruction"])})
      )

    Shared.put_demos(
      candidate,
      Map.new(names, &{&1, Map.fetch!(Enum.at(demo_sets, choice["#{&1}.demos"]), &1)})
    )
  end

  defp trials(config, _tpe, _build, state, ctx, trial) when trial > config.num_trials,
    do: {state, ctx}

  defp trials(config, tpe, build, state, ctx, trial) do
    if Context.exhausted?(ctx) do
      {state, ctx}
    else
      {choice, ctx} = TPE.suggest(tpe, Enum.reverse(state.observations), ctx)
      {batch, ctx} = Context.sample(ctx, ctx.train, config.minibatch_size)
      {evaluation, ctx} = Context.evaluate(ctx, build.(choice), batch)

      if evaluation.complete? do
        score =
          evaluation.selected_score || Tune.Evaluation.mean(evaluation) || ctx.failure_score || 0

        state = %{
          state
          | observations: [{choice, score} | state.observations],
            minibatch: Map.update(state.minibatch, choice, [score], &[score | &1]),
            trials: [
              %{trial: trial, choice: choice, minibatch: Enum.map(batch, & &1.id), score: score}
              | state.trials
            ]
        }

        {state, ctx} =
          if rem(trial, config.minibatch_full_eval_steps) == 0,
            do: promote(build, state, ctx),
            else: {state, ctx}

        trials(config, tpe, build, state, ctx, trial + 1)
      else
        {state, ctx}
      end
    end
  end

  defp promote(build, state, ctx) do
    best =
      state.minibatch
      |> Enum.reject(fn {choice, _} -> MapSet.member?(state.promoted, choice) end)
      |> Enum.sort_by(fn {choice, scores} ->
        {-(Enum.sum(scores) / length(scores)), Tune.CanonicalJSON.encode!(choice)}
      end)
      |> List.first()

    case best do
      nil ->
        {state, ctx}

      {choice, scores} ->
        if Context.exhausted?(ctx) do
          {state, ctx}
        else
          candidate = build.(choice)
          {evaluation, ctx} = Context.evaluate_validation(ctx, candidate)

          {_id, ctx} =
            Context.consider(ctx, candidate, evaluation, %{
              label: "trial",
              choice: choice,
              minibatch_mean: Enum.sum(scores) / length(scores)
            })

          {%{state | promoted: MapSet.put(state.promoted, choice)}, ctx}
        end
    end
  end
end
