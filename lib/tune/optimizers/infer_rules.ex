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

  @behaviour Tune.Search.ProgramStrategy

  alias Tune.Optimizers.BootstrapFewShot
  alias Tune.Optimizers.BootstrapFewShotWithRandomSearch
  alias Tune.Optimizers.ExampleSets
  alias Tune.Optimizers.Proposals
  alias Tune.Optimizers.Shared
  alias Tune.Search.Program.Context

  @fields [
    num_candidates: Zoi.integer() |> Zoi.positive() |> Zoi.default(2),
    num_rules: Zoi.integer() |> Zoi.positive() |> Zoi.default(5)
  ]
  @options Zoi.keyword(@fields, unrecognized_keys: :error)
  @rules_header "Please adhere to the following rules when making your prediction:"

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
    {original, ctx} = Context.evaluate_validation(ctx, program)
    {_id, ctx} = Context.consider(ctx, program, original, %{label: "original"})

    case BootstrapFewShot.build(ExampleSets.bootstrap_config(config), program, ctx.train, ctx) do
      {:ok, bootstrapped, ctx} ->
        {evaluation, ctx} = Context.evaluate_validation(ctx, bootstrapped)
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

  defp candidate(config, bootstrapped, index, %Context{} = ctx) do
    if Context.budget(ctx) == 0,
      do: ctx,
      else: build_candidate(config, bootstrapped, index, ctx)
  end

  defp build_candidate(config, bootstrapped, index, ctx) do
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
        {evaluation, ctx} = Context.evaluate_validation(ctx, candidate)

        {_id, ctx} =
          Context.consider(ctx, candidate, evaluation, %{label: "rules_#{index}", rules: rules})

        ctx
      end
    end
  end
end
