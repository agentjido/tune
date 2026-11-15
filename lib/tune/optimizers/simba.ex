defmodule Tune.Optimizers.SIMBA do
  @moduledoc """
  Stochastic introspective mini-batch ascent.

  Each of `max_steps` steps:

  1. takes the next training minibatch of `bsz` rows from a seeded shuffle;
  2. runs `num_candidates` trajectories per row, each with a program sampled
     from the pool by a softmax over mean minibatch scores (`temperature`);
  3. ranks rows by the gap between their best and worst trajectory scores,
     then by lowest best score, so variable and then weak behavior is
     targeted first;
  4. for the top `num_candidates` rows, builds a new candidate from a sampled
     pool program with one strategy, chosen at random:
     * `append_a_demo` adds the best trajectory's final call per predictor as a
       demonstration (keeping at most `max_demos`),
     * `append_a_rule` asks the proposal role to contrast the best and worst
       trajectory and appends the advice to one predictor's instruction;
     the positive trajectory is the row's own best when it succeeded and
     beat its worst; for a weak row with no gap, it is the best successful
     trajectory of another minibatch row that scored higher. A row with no
     such positive is skipped, so failures never become demonstrations;
  5. scores new candidates on the same minibatch and adds them to the pool.

  Finally the baseline and the `num_final` best pool programs by mean
  minibatch score are evaluated on the full validation set; only a complete,
  eligible validation result is returned.

  Options: `:bsz` (default 4), `:num_candidates` (default 4), `:max_steps`
  (default 4), `:max_demos` (default 4), `:temperature` (default 0.2),
  `:num_final` (default 3).

  Differences from DSPy: trajectory variation comes from sampling pool
  programs, not from changing the model temperature; final selection uses
  the explicit validation set.
  """

  @behaviour Tune.Search.ProgramStrategy

  alias Tune.Demo
  alias Tune.Optimizers.Proposals
  alias Tune.Optimizers.Shared
  alias Tune.Search.Program.Context

  @options [:bsz, :num_candidates, :max_steps, :max_demos, :temperature, :num_final, :strategies]

  @impl true
  def init(opts) do
    defaults = [
      bsz: 4,
      num_candidates: 4,
      max_steps: 4,
      max_demos: 4,
      temperature: 0.2,
      num_final: 3,
      strategies: [:append_a_demo, :append_a_rule]
    ]

    with {:ok, opts} <- Shared.require_options(opts, @options, defaults),
         :ok <-
           Shared.with_checks([
             fn -> Shared.positive(opts, :bsz) end,
             fn -> Shared.positive(opts, :num_candidates) end,
             fn -> Shared.positive(opts, :max_steps) end,
             fn -> Shared.non_negative(opts, :max_demos) end,
             fn -> Shared.positive(opts, :num_final) end,
             fn ->
               if is_number(opts[:temperature]) and opts[:temperature] > 0,
                 do: :ok,
                 else: Shared.option_error(:temperature, "must be a positive number")
             end,
             fn -> check_strategies(opts[:strategies]) end
           ]) do
      {:ok, Map.new(opts)}
    end
  end

  @impl true
  def requirements(_config),
    do: %{datasets: [:train, :val], roles: [:proposal], model_calls?: true}

  @impl true
  def compile(config, program, %Context{} = ctx) do
    {order, ctx} = Context.shuffle(ctx, ctx.trainset)

    state = %{
      pool: [%{id: 0, program: program, scores: [], parent: nil, strategy: :baseline}],
      next: 1,
      order: order,
      cursor: 0,
      steps: []
    }

    {state, ctx} = steps(config, state, ctx, 1)
    ctx = Context.note(ctx, :steps, Enum.reverse(state.steps))
    ctx = finalize(config, state, ctx)
    ctx = if Context.exhausted?(ctx), do: Context.stop(ctx, :budget_exhausted), else: ctx
    Context.best(ctx)
  end

  defp steps(config, state, ctx, step) when step > config.max_steps, do: {state, ctx}

  defp steps(config, state, ctx, step) do
    if Context.exhausted?(ctx) do
      {state, ctx}
    else
      {batch, state} = next_batch(config, state)
      {buckets, ctx} = trajectories(config, state, batch, ctx)

      ranked =
        buckets
        |> Enum.sort_by(fn b -> {-(b.max - b.min), b.max, b.index} end)
        |> Enum.take(config.num_candidates)

      {created, state, ctx} = mutate(config, ranked, buckets, state, ctx)
      {state, ctx} = score_new(created, batch, state, ctx)

      record = %{
        step: step,
        batch: Enum.map(batch, & &1.id),
        targeted: Enum.map(ranked, &%{row: &1.example.id, gap: &1.max - &1.min}),
        created: Enum.map(created, &Map.take(&1, [:id, :parent, :strategy, :predictor, :row]))
      }

      steps(config, %{state | steps: [record | state.steps]}, ctx, step + 1)
    end
  end

  defp next_batch(config, state) do
    n = length(state.order)

    batch =
      Enum.map(0..(config.bsz - 1), fn i -> Enum.at(state.order, rem(state.cursor + i, n)) end)
      |> Enum.uniq_by(& &1.id)

    {batch, %{state | cursor: rem(state.cursor + config.bsz, n)}}
  end

  defp trajectories(config, state, batch, ctx) do
    batch
    |> Enum.with_index()
    |> Enum.reduce({[], ctx}, fn {example, index}, {acc, ctx} ->
      {runs, ctx} =
        Enum.reduce(1..config.num_candidates, {[], ctx}, fn _, {runs, ctx} ->
          if Context.exhausted?(ctx) do
            {runs, ctx}
          else
            {entry, ctx} = sample_program(config, state.pool, ctx)
            {outcome, ctx} = Context.run(ctx, entry.program, example.input, :target)
            {[%{entry: entry, outcome: outcome, score: score(ctx, example, outcome)} | runs], ctx}
          end
        end)

      case runs do
        [] ->
          {acc, ctx}

        runs ->
          scores = Enum.map(runs, & &1.score)

          {[
             %{
               index: index,
               example: example,
               runs: Enum.reverse(runs),
               max: Enum.max(scores),
               min: Enum.min(scores)
             }
             | acc
           ], ctx}
      end
    end)
    |> then(fn {buckets, ctx} -> {Enum.reverse(buckets), ctx} end)
  end

  defp score(ctx, example, {:ok, result}) do
    case Context.score(ctx, example, result) do
      {:ok, %{score: score}} -> score
      {:error, _} -> ctx.failure_score || 0
    end
  end

  defp score(ctx, _example, {:error, _}), do: ctx.failure_score || 0

  defp mutate(config, buckets, all_buckets, state, ctx) do
    Enum.reduce(buckets, {[], state, ctx}, fn bucket, {created, state, ctx} ->
      worst =
        Enum.min_by(Enum.with_index(bucket.runs), fn {run, i} -> {run.score, i} end) |> elem(0)

      best = positive(bucket, all_buckets, worst)

      if best != nil and not Context.exhausted?(ctx) do
        {source, ctx} = sample_program(config, state.pool, ctx)
        {strategy, ctx} = pick(ctx, config.strategies)

        case apply_strategy(strategy, config, source.program, best, worst, ctx) do
          {{:ok, program, predictor}, ctx} ->
            entry = %{
              id: state.next,
              program: program,
              scores: [],
              parent: source.id,
              strategy: strategy,
              predictor: predictor,
              row: bucket.example.id
            }

            {[entry | created], %{state | pool: state.pool ++ [entry], next: state.next + 1}, ctx}

          {:skip, ctx} ->
            {created, state, ctx}
        end
      else
        {created, state, ctx}
      end
    end)
    |> then(fn {created, state, ctx} -> {Enum.reverse(created), state, ctx} end)
  end

  defp positive(bucket, all_buckets, worst) do
    own = Enum.max_by(Enum.with_index(bucket.runs), fn {run, i} -> {run.score, -i} end) |> elem(0)

    if match?({:ok, _}, own.outcome) and own.score > worst.score do
      own
    else
      all_buckets
      |> Enum.flat_map(& &1.runs)
      |> Enum.filter(&(match?({:ok, _}, &1.outcome) and &1.score > worst.score))
      |> Enum.max_by(& &1.score, fn -> nil end)
    end
  end

  defp apply_strategy(:append_a_demo, config, program, best, _worst, ctx) do
    {:ok, result} = best.outcome
    names = Enum.map(Shared.predictors(program), &elem(&1, 0))
    demos = Shared.trajectory_demos(result, names)

    if demos == %{} or config.max_demos == 0 do
      {:skip, ctx}
    else
      predictors = Map.new(Shared.predictors(program))

      updated =
        Map.new(demos, fn {name, %Demo{} = demo} ->
          existing = Enum.reject(Map.fetch!(predictors, name).demos, &(&1.inputs == demo.inputs))
          {name, Enum.take([demo | existing], config.max_demos)}
        end)

      {{:ok, Shared.put_demos(program, updated),
        Map.keys(updated) |> Enum.sort() |> Enum.join(",")}, ctx}
    end
  end

  defp apply_strategy(:append_a_rule, _config, program, best, worst, ctx) do
    predictors = Shared.predictors(program)
    {index, ctx} = Context.uniform(ctx, length(predictors))
    {name, predictor} = Enum.at(predictors, index)

    {advice, ctx} =
      Proposals.contrast(
        ctx,
        Proposals.describe(predictor),
        predictor.signature.instructions,
        render(best),
        render(worst)
      )

    case advice do
      nil ->
        {:skip, ctx}

      text ->
        {:ok, updated} =
          Shared.put_instructions(program, %{
            name => predictor.signature.instructions <> "\n\n" <> text
          })

        {{:ok, updated, name}, ctx}
    end
  end

  defp render(%{outcome: {:ok, result}, score: score}) do
    "score: #{score}\n" <>
      Enum.map_join(result.steps, "\n", &("#{&1.name}: " <> Shared.render_step(&1)))
  end

  defp render(%{outcome: {:error, error}, score: score}) do
    message = if is_exception(error), do: Exception.message(error), else: inspect(error)
    "score: #{score}\nfailed: #{message}"
  end

  defp score_new(created, batch, state, ctx) do
    Enum.reduce(created, {state, ctx}, fn entry, {state, ctx} ->
      if Context.exhausted?(ctx) do
        {state, ctx}
      else
        {evaluation, ctx} = Context.evaluate(ctx, entry.program, batch)

        if evaluation.complete? do
          value =
            evaluation.selected_score || Tune.Evaluation.mean(evaluation) || ctx.failure_score ||
              0

          pool =
            Enum.map(state.pool, fn e ->
              if e.id == entry.id, do: %{e | scores: [value | e.scores]}, else: e
            end)

          {%{state | pool: pool}, ctx}
        else
          {state, ctx}
        end
      end
    end)
  end

  defp finalize(config, state, ctx) do
    [baseline | rest] = state.pool

    finalists =
      rest
      |> Enum.filter(&(&1.scores != []))
      |> Enum.sort_by(fn e -> {-mean(e.scores), e.id} end)
      |> Enum.take(config.num_final)

    Enum.reduce([baseline | finalists], ctx, fn entry, ctx ->
      if Context.exhausted?(ctx) do
        ctx
      else
        {evaluation, ctx} = Context.evaluate_validation(ctx, entry.program)

        {_id, ctx} =
          Context.consider(ctx, entry.program, evaluation, %{
            label: to_string(entry.strategy),
            pool_id: entry.id,
            parent: entry.parent,
            minibatch_mean: if(entry.scores == [], do: nil, else: mean(entry.scores))
          })

        ctx
      end
    end)
  end

  defp sample_program(config, pool, ctx) do
    weights =
      Enum.map(pool, fn entry ->
        :math.exp(if(entry.scores == [], do: 0.0, else: mean(entry.scores)) / config.temperature)
      end)

    {r, ctx} = Context.random(ctx)
    target = r * Enum.sum(weights)

    index =
      weights
      |> Enum.with_index()
      |> Enum.reduce_while(target, fn {w, i}, left ->
        if left < w, do: {:halt, {:i, i}}, else: {:cont, left - w}
      end)
      |> case do
        {:i, i} -> i
        _ -> length(pool) - 1
      end

    {Enum.at(pool, index), ctx}
  end

  defp pick(ctx, [only]), do: {only, ctx}

  defp pick(ctx, strategies) do
    {i, ctx} = Context.uniform(ctx, length(strategies))
    {Enum.at(strategies, i), ctx}
  end

  defp mean(values), do: Enum.sum(values) / length(values)

  defp check_strategies(strategies) when is_list(strategies) and strategies != [] do
    if Enum.all?(strategies, &(&1 in [:append_a_demo, :append_a_rule])),
      do: :ok,
      else: Shared.option_error(:strategies, "must be :append_a_demo and/or :append_a_rule")
  end

  defp check_strategies(_), do: Shared.option_error(:strategies, "must be a nonempty list")
end
