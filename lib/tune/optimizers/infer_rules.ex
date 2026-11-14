defmodule Tune.Optimizers.InferRules do
  @moduledoc """
  Derives natural-language rules from bootstrapped examples.

  The program is bootstrapped with the teacher role. The original program and
  the bootstrapped program are evaluated on the validation set and both stay
  selectable. Then `num_candidates` rule candidates are built: for each
  predictor, the proposal role derives up to `num_rules` rules from a shuffled
  view of that predictor's bootstrapped demonstrations, and the rules are
  appended to its instruction. Each candidate keeps the bootstrapped
  demonstrations and is evaluated on validation; the best complete eligible
  candidate is returned, so a worse rule set is never chosen.

  Options: `:num_candidates` (default 2), `:num_rules` (default 5), and
  BootstrapFewShot options (`:accept_score` required).
  """

  @behaviour Tune.Optimizer

  alias Tune.Optimizer.Context
  alias Tune.Optimizers.BootstrapFewShot
  alias Tune.Optimizers.BootstrapFewShotWithRandomSearch
  alias Tune.Optimizers.ExampleSets
  alias Tune.Optimizers.Proposals
  alias Tune.Optimizers.Shared

  @own [:num_candidates, :num_rules]
  @rules_header "Please adhere to the following rules when making your prediction:"

  @impl true
  def init(opts) do
    {own, boot} = Keyword.split(opts, @own)

    with {:ok, own} <- Shared.require_options(own, @own, num_candidates: 2, num_rules: 5),
         :ok <-
           Shared.with_checks([
             fn -> Shared.positive(own, :num_candidates) end,
             fn -> Shared.positive(own, :num_rules) end
           ]),
         {:ok, boot} <- BootstrapFewShot.init(boot),
         :ok <- BootstrapFewShotWithRandomSearch.require_accept(boot) do
      {:ok, Map.merge(boot, Map.new(own))}
    end
  end

  @impl true
  def requirements(_config),
    do: %{datasets: [:train, :val], roles: [:teacher, :proposal], model_calls?: true}

  @impl true
  def compile(config, program, %Context{} = ctx) do
    {original, ctx} = Context.evaluate(ctx, program, ctx.valset)
    {_id, ctx} = Context.consider(ctx, program, original, %{label: "original"})

    case BootstrapFewShot.build(ExampleSets.bootstrap_config(config), program, ctx.trainset, ctx) do
      {:ok, bootstrapped, ctx} ->
        {evaluation, ctx} = Context.evaluate(ctx, bootstrapped, ctx.valset)
        {_id, ctx} = Context.consider(ctx, bootstrapped, evaluation, %{label: "bootstrapped"})
        ctx = Enum.reduce(1..config.num_candidates, ctx, &candidate(config, bootstrapped, &1, &2))
        ctx = if Context.exhausted?(ctx), do: Context.stop(ctx, :budget_exhausted), else: ctx
        Context.best(ctx)

      {:error, _error, ctx} ->
        Context.best(Context.stop(ctx, :budget_exhausted))
    end
  end

  @doc "Appends rules to an instruction in the inspectable format used by InferRules."
  @spec with_rules(String.t(), [String.t()]) :: String.t()
  def with_rules(instruction, rules) do
    numbered =
      rules |> Enum.with_index(1) |> Enum.map_join("\n", fn {rule, i} -> "#{i}. #{rule}" end)

    instruction <> "\n\n" <> @rules_header <> "\n" <> numbered
  end

  defp candidate(_config, _bootstrapped, _index, %Context{} = ctx) when ctx.budget == 0, do: ctx

  defp candidate(config, bootstrapped, index, ctx) do
    if Context.exhausted?(ctx) do
      ctx
    else
      {instructions, rules, ctx} =
        Enum.reduce(Shared.predictors(bootstrapped), {%{}, %{}, ctx}, fn {name, predictor},
                                                                         {acc, all, ctx} ->
          {demos, ctx} = Context.shuffle(ctx, predictor.demos)

          examples =
            if demos == [], do: "None.", else: Enum.map_join(demos, "\n\n", &Shared.render_step/1)

          {rules, ctx} =
            Proposals.rules(ctx, Proposals.describe(predictor), examples, config.num_rules)

          if rules == [],
            do: {acc, all, ctx},
            else:
              {Map.put(acc, name, with_rules(predictor.signature.instructions, rules)),
               Map.put(all, name, rules), ctx}
        end)

      if instructions == %{} or Context.exhausted?(ctx) do
        ctx
      else
        {:ok, candidate} = Shared.put_instructions(bootstrapped, instructions)
        {evaluation, ctx} = Context.evaluate(ctx, candidate, ctx.valset)

        {_id, ctx} =
          Context.consider(ctx, candidate, evaluation, %{label: "rules_#{index}", rules: rules})

        ctx
      end
    end
  end
end
