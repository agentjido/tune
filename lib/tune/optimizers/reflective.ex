defmodule Tune.Optimizers.Reflective do
  @moduledoc """
  The reflective evolutionary search shared by GEPA and Optimize.Anything.

  A component is one tunable text: a predictor instruction, or a declared
  parameter value rendered as text. The search keeps a pool of candidates,
  each fully evaluated on the validation set with per-row scores and
  lineage. Each iteration either:

    * reflects: selects a parent from the per-row Pareto frontier (a
      candidate is sampled in proportion to the number of validation rows on
      which it has the best score), picks the parent's next component round
      robin, runs the parent on a training minibatch, sends the trajectories
      with their scores and metric feedback to the proposal role, and builds a
      child with the proposed text. The child is scored on the same
      minibatch and gets a full validation pass only if it beats the parent's
      minibatch total; or
    * merges: every `merge_every` iterations, finds two pool candidates with a
      common ancestor that changed different components, combines those
      changes into one child, and validates it.

  Only complete, eligible validation results can become the incumbent; ties
  keep the earlier candidate.
  """

  alias Tune.Case
  alias Tune.Evaluation
  alias Tune.Optimizers.Shared
  alias Tune.Search.Program.Context

  @type component :: %{
          name: String.t(),
          get: (Tune.t() -> String.t()),
          put: (Tune.t(), String.t() -> {:ok, Tune.t()} | {:error, term()}),
          propose: (Context.t(), String.t(), String.t() -> {String.t() | nil, Context.t()})
        }

  @doc false
  def options(fields) do
    Zoi.keyword(
      fields ++
        [
          max_iterations: Zoi.integer() |> Zoi.positive() |> Zoi.default(8),
          minibatch_size: Zoi.integer() |> Zoi.positive() |> Zoi.default(3),
          use_merge: Zoi.boolean() |> Zoi.default(true),
          merge_every: Zoi.integer() |> Zoi.positive() |> Zoi.default(3)
        ],
      unrecognized_keys: :error
    )
  end

  @spec run(map(), Tune.t(), [component()], Context.t()) ::
          {:ok, Tune.t(), Context.t()} | {:error, term(), Context.t()}
  def run(config, program, components, ctx) do
    {evaluation, ctx} = Context.evaluate_validation(ctx, program)
    {id, ctx} = Context.consider(ctx, program, evaluation, %{label: "baseline", parents: []})
    {order, ctx} = Context.shuffle(ctx, ctx.train)

    state = %{
      pool: [entry(id, program, evaluation, [], components)],
      ancestry: %{id => []},
      cursor: 0,
      order: order,
      next_component: %{},
      merged: MapSet.new(),
      log: []
    }

    {state, ctx} =
      if evaluation.complete?, do: loop(config, components, state, ctx, 1), else: {state, ctx}

    ctx =
      ctx
      |> Context.note(:iterations, Enum.reverse(state.log))
      |> Context.note(:pool, Enum.map(state.pool, &Map.take(&1, [:id, :parents, :mean, :texts])))
      |> then(&if(Context.exhausted?(&1), do: Context.stop(&1, :budget_exhausted), else: &1))

    Context.best(ctx)
  end

  defp entry(id, program, %Evaluation{} = evaluation, parents, components) do
    %{
      id: id,
      program: program,
      parents: parents,
      mean: evaluation.selected_score,
      row_scores: Map.new(evaluation.observations, &{&1.id, row_score(&1, evaluation)}),
      texts: Map.new(components, &{&1.name, &1.get.(program)})
    }
  end

  defp row_score(%{status: :ok, metadata: %{selected_score: score}}, _evaluation), do: score

  defp row_score(%{metadata: metadata}, _evaluation), do: Map.get(metadata, :selected_score)

  defp loop(config, _components, state, ctx, iteration) when iteration > config.max_iterations,
    do: {state, ctx}

  defp loop(config, components, state, ctx, iteration) do
    if Context.exhausted?(ctx) do
      {state, ctx}
    else
      {state, ctx} =
        if config.use_merge and rem(iteration, config.merge_every) == 0 do
          case merge(components, state, ctx, iteration) do
            {:none, state, ctx} -> reflect(config, components, state, ctx, iteration)
            {:ok, state, ctx} -> {state, ctx}
          end
        else
          reflect(config, components, state, ctx, iteration)
        end

      loop(config, components, state, ctx, iteration + 1)
    end
  end

  defp reflect(config, components, state, ctx, iteration) do
    {parent, ctx} = select_parent(state.pool, ctx)
    index = Map.get(state.next_component, parent.id, 0)
    component = Enum.at(components, rem(index, length(components)))
    state = put_in(state.next_component[parent.id], index + 1)
    {batch, state} = minibatch(config, state)
    {traces, ctx} = traces(parent.program, batch, ctx)
    parent_total = Enum.sum(Enum.map(traces, & &1.score))
    {text, ctx} = component.propose.(ctx, component.get.(parent.program), render(traces))

    with text when is_binary(text) <- text,
         false <- text == component.get.(parent.program),
         {:ok, child} <- component.put.(parent.program, text),
         false <- Context.exhausted?(ctx) do
      {mini, ctx} = Context.evaluate(ctx, child, batch)
      child_total = minibatch_total(mini, ctx)

      if mini.complete? and child_total > parent_total and not Context.exhausted?(ctx) do
        {evaluation, ctx} = Context.evaluate_validation(ctx, child)

        {state, ctx} =
          admit(child, evaluation, [parent.id], components, state, ctx, %{
            label: "reflect",
            component: component.name
          })

        {log(
           state,
           iteration,
           :reflect,
           parent.id,
           component.name,
           true,
           child_total,
           parent_total
         ), ctx}
      else
        {log(
           state,
           iteration,
           :reflect,
           parent.id,
           component.name,
           false,
           child_total,
           parent_total
         ), ctx}
      end
    else
      _ ->
        {log(state, iteration, :reflect, parent.id, component.name, false, nil, parent_total),
         ctx}
    end
  end

  defp admit(child, evaluation, parents, components, state, ctx, meta) do
    {id, ctx} = Context.consider(ctx, child, evaluation, Map.put(meta, :parents, parents))

    if evaluation.complete? do
      ancestry = Enum.uniq(parents ++ Enum.flat_map(parents, &Map.get(state.ancestry, &1, [])))

      state = %{
        state
        | pool: state.pool ++ [entry(id, child, evaluation, parents, components)],
          ancestry: Map.put(state.ancestry, id, ancestry)
      }

      {state, ctx}
    else
      {state, ctx}
    end
  end

  defp log(state, iteration, kind, parent, component, accepted?, child_total, parent_total) do
    record = %{
      iteration: iteration,
      kind: kind,
      parent: parent,
      component: component,
      accepted?: accepted?,
      child_minibatch: child_total,
      parent_minibatch: parent_total
    }

    %{state | log: [record | state.log]}
  end

  defp minibatch_total(%Evaluation{} = evaluation, _ctx) do
    Enum.sum(
      Enum.map(evaluation.observations, fn
        %{status: :ok, metadata: %{selected_score: score}} -> score
        %{metadata: metadata} -> Map.get(metadata, :selected_score, 0)
      end)
    )
  end

  @doc false
  @spec traces(Tune.t(), [Case.t()], Context.t()) :: {[map()], Context.t()}
  def traces(program, batch, ctx) do
    Enum.reduce(batch, {[], ctx}, fn example, {acc, ctx} ->
      {outcome, ctx} = Context.run(ctx, program, example.input, :target)

      {trace, ctx} = trace(ctx, example, outcome)

      {[trace | acc], ctx}
    end)
    |> then(fn {traces, ctx} -> {Enum.reverse(traces), ctx} end)
  end

  defp trace(ctx, example, {:ok, result}) do
    {outcome, ctx} = Context.score(ctx, example, result)

    trace =
      case outcome do
        {:ok, %{score: score, feedback: feedback}} ->
          %{example: example, result: result, score: score, feedback: feedback, error: nil}

        {:error, error} ->
          failed_trace(ctx, example, result, error)
      end

    {trace, ctx}
  end

  defp trace(ctx, example, {:error, error}), do: {failed_trace(ctx, example, nil, error), ctx}

  defp failed_trace(ctx, example, result, error) do
    %{
      example: example,
      result: result,
      score: ctx.failure_score || 0,
      feedback: nil,
      error: error
    }
  end

  @doc false
  @spec render([map()]) :: String.t()
  def render(traces) do
    Enum.map_join(traces, "\n\n", fn trace ->
      steps =
        case trace.result do
          nil -> "no completed steps"
          result -> Enum.map_join(result.steps, "\n", &("#{&1.name}: " <> Shared.render_step(&1)))
        end

      error = if trace.error, do: "\nerror: " <> describe(trace.error), else: ""
      feedback = if trace.feedback, do: "\nfeedback: " <> trace.feedback, else: ""

      "inputs: #{Tune.CanonicalJSON.encode!(trace.example.input)}\n#{steps}\nscore: #{trace.score}#{feedback}#{error}"
    end)
  end

  defp describe(error) when is_exception(error), do: Exception.message(error)
  defp describe(error), do: inspect(error)

  defp minibatch(config, state) do
    n = length(state.order)

    batch =
      Enum.map(0..(config.minibatch_size - 1), &Enum.at(state.order, rem(state.cursor + &1, n)))
      |> Enum.uniq_by(& &1.id)

    {batch, %{state | cursor: rem(state.cursor + config.minibatch_size, n)}}
  end

  @doc false
  @spec frontier_counts([map()]) :: %{non_neg_integer() => non_neg_integer()}
  def frontier_counts(pool) do
    rows = pool |> Enum.flat_map(&Map.keys(&1.row_scores)) |> Enum.uniq()

    Enum.reduce(rows, %{}, fn row, acc ->
      scored =
        for entry <- pool, score = entry.row_scores[row], score != nil, do: {entry.id, score}

      case scored do
        [] ->
          acc

        scored ->
          top = scored |> Enum.map(&elem(&1, 1)) |> Enum.max()

          scored
          |> Enum.filter(&(elem(&1, 1) == top))
          |> Enum.reduce(acc, fn {id, _}, acc -> Map.update(acc, id, 1, &(&1 + 1)) end)
      end
    end)
  end

  defp select_parent([only], ctx), do: {only, ctx}

  defp select_parent(pool, ctx) do
    counts = frontier_counts(pool)
    weighted = Enum.map(pool, &{&1, Map.get(counts, &1.id, 0)})
    total = weighted |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    if total == 0 do
      {i, ctx} = Context.uniform(ctx, length(pool))
      {Enum.at(pool, i), ctx}
    else
      {r, ctx} = Context.uniform(ctx, total)

      chosen =
        Enum.reduce_while(weighted, r, fn {entry, w}, left ->
          if left < w, do: {:halt, {:entry, entry}}, else: {:cont, left - w}
        end)

      {elem(chosen, 1), ctx}
    end
  end

  defp merge(components, state, ctx, iteration) do
    pairs =
      for a <- state.pool,
          b <- state.pool,
          a.id < b.id,
          not MapSet.member?(state.merged, {a.id, b.id}),
          ancestor = common_ancestor(state, a, b),
          ancestor != nil,
          changed_a = changed(a, ancestor),
          changed_b = changed(b, ancestor),
          changed_a != [] and changed_b != [] and
            MapSet.disjoint?(MapSet.new(changed_a), MapSet.new(changed_b)),
          do: {a, b, ancestor, changed_a, changed_b}

    case pairs do
      [] ->
        {:none, state, ctx}

      [{a, b, ancestor, changed_a, changed_b} | _] ->
        state = %{state | merged: MapSet.put(state.merged, {a.id, b.id})}
        texts = Map.merge(Map.take(a.texts, changed_a), Map.take(b.texts, changed_b))

        result =
          Enum.reduce_while(components, {:ok, ancestor.program}, fn component, {:ok, program} ->
            case Map.fetch(texts, component.name) do
              {:ok, text} ->
                case component.put.(program, text) do
                  {:ok, program} -> {:cont, {:ok, program}}
                  error -> {:halt, error}
                end

              :error ->
                {:cont, {:ok, program}}
            end
          end)

        case result do
          {:ok, child} ->
            {evaluation, ctx} = Context.evaluate_validation(ctx, child)

            {state, ctx} =
              admit(child, evaluation, [a.id, b.id], components, state, ctx, %{
                label: "merge",
                merged_from: [a.id, b.id],
                ancestor: ancestor.id
              })

            record = %{
              iteration: iteration,
              kind: :merge,
              parents: [a.id, b.id],
              ancestor: ancestor.id,
              accepted?: evaluation.complete?
            }

            {:ok, %{state | log: [record | state.log]}, ctx}

          _ ->
            {:none, state, ctx}
        end
    end
  end

  defp common_ancestor(state, a, b) do
    ancestors_a = MapSet.new(Map.get(state.ancestry, a.id, []))
    ancestors_b = Map.get(state.ancestry, b.id, [])

    ancestors_b
    |> Enum.filter(&MapSet.member?(ancestors_a, &1))
    |> Enum.max(fn -> nil end)
    |> case do
      nil -> nil
      id -> Enum.find(state.pool, &(&1.id == id))
    end
  end

  defp changed(entry, ancestor) do
    for {name, text} <- entry.texts, Map.get(ancestor.texts, name) != text, do: name
  end
end
