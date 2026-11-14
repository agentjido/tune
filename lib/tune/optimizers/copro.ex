defmodule Tune.Optimizers.COPRO do
  @moduledoc """
  Coordinate instruction search over predictors.

  The unchanged program is evaluated first. Then, for `depth` rounds, each
  predictor in name order gets `breadth` proposed instructions from the
  proposal role. The first round proposes from the current instruction and
  training evidence; later rounds also see that predictor's earlier attempts
  and their validation scores. Each proposal is evaluated with the other
  predictors fixed at the incumbent, and a strictly better complete eligible
  result becomes the new incumbent before the next predictor is tried.

  Options: `:breadth` (default 4), `:depth` (default 2), `:evidence_examples`
  (default 3), and `:predictors` (names to search; default all).

  Differences from DSPy: candidates are scored on the explicit validation set,
  not the training set; proposals are one typed call returning a list rather
  than `n` sampled completions; no temperature is changed.
  """

  @behaviour Tune.Optimizer

  alias Tune.Optimizer.Context
  alias Tune.Optimizers.Proposals
  alias Tune.Optimizers.Shared

  @options [:breadth, :depth, :evidence_examples, :predictors]

  @impl true
  def init(opts) do
    with {:ok, opts} <-
           Shared.require_options(opts, @options,
             breadth: 4,
             depth: 2,
             evidence_examples: 3,
             predictors: nil
           ),
         :ok <-
           Shared.with_checks([
             fn -> Shared.positive(opts, :breadth) end,
             fn -> Shared.positive(opts, :depth) end,
             fn -> Shared.non_negative(opts, :evidence_examples) end,
             fn -> check_names(opts[:predictors]) end
           ]) do
      {:ok, Map.new(opts)}
    end
  end

  @impl true
  def requirements(_config),
    do: %{datasets: [:train, :val], roles: [:proposal], model_calls?: true}

  @impl true
  def compile(config, program, %Context{} = ctx) do
    case target_names(config, program) do
      {:ok, names} -> search(config, program, names, ctx)
      {:error, error} -> {:error, error, ctx}
    end
  end

  @doc false
  def search(config, program, names, ctx) do
    {evaluation, ctx} = Context.evaluate(ctx, program, ctx.valset)

    {baseline_id, ctx} =
      Context.consider(ctx, program, evaluation, %{label: "baseline", parent: nil})

    evidence = Proposals.evidence(ctx.trainset, config.evidence_examples)
    state = %{current: program, current_id: baseline_id, attempts: Map.new(names, &{&1, []})}

    {_state, ctx} =
      Enum.reduce_while(1..config.depth, {state, ctx}, fn round, {state, ctx} ->
        {state, ctx} =
          Enum.reduce_while(names, {state, ctx}, fn name, {state, ctx} ->
            if Context.exhausted?(ctx),
              do: {:halt, {state, ctx}},
              else: {:cont, step(config, name, round, evidence, state, ctx)}
          end)

        if Context.exhausted?(ctx), do: {:halt, {state, ctx}}, else: {:cont, {state, ctx}}
      end)

    ctx = if Context.exhausted?(ctx), do: Context.stop(ctx, :budget_exhausted), else: ctx
    Context.best(ctx)
  end

  defp step(config, name, round, evidence, state, ctx) do
    current = Map.new(Shared.predictors(state.current)) |> Map.fetch!(name)

    {proposals, ctx} =
      Proposals.instructions(ctx, current,
        n: config.breadth,
        evidence: evidence,
        attempts: render_attempts(state.attempts[name])
      )

    Enum.reduce_while(proposals, {state, ctx}, fn instruction, {state, ctx} ->
      if Context.exhausted?(ctx) do
        {:halt, {state, ctx}}
      else
        {:ok, candidate} = Shared.put_instructions(state.current, %{name => instruction})
        {evaluation, ctx} = Context.evaluate(ctx, candidate, ctx.valset)
        before = ctx.best

        {id, ctx} =
          Context.consider(ctx, candidate, evaluation, %{
            label: "#{name}@#{round}",
            parent: state.current_id,
            predictor: name,
            instruction: instruction
          })

        state = update_in(state.attempts[name], &[{instruction, evaluation.selection_score} | &1])

        state =
          if ctx.best != before, do: %{state | current: candidate, current_id: id}, else: state

        {:cont, {state, ctx}}
      end
    end)
  end

  defp render_attempts([]), do: "None."

  defp render_attempts(attempts) do
    attempts
    |> Enum.reverse()
    |> Enum.map_join("\n", fn {instruction, score} ->
      "score #{if score, do: Float.round(score * 1.0, 4), else: "ineligible"}: #{instruction}"
    end)
  end

  defp target_names(%{predictors: nil}, program),
    do: {:ok, Enum.map(Shared.predictors(program), &elem(&1, 0))}

  defp target_names(%{predictors: names}, program) do
    declared = Enum.map(Shared.predictors(program), &elem(&1, 0))

    case names -- declared do
      [] -> {:ok, Enum.sort(names)}
      unknown -> Shared.option_error(:predictors, "unknown predictors: #{inspect(unknown)}")
    end
  end

  defp check_names(nil), do: :ok

  defp check_names([_ | _] = names),
    do:
      if(Enum.all?(names, &is_binary/1),
        do: :ok,
        else: Shared.option_error(:predictors, "must be names")
      )

  defp check_names(_), do: Shared.option_error(:predictors, "must be a nonempty list of names")
end
