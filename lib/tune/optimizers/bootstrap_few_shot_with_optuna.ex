defmodule Tune.Optimizers.BootstrapFewShotWithOptuna do
  @moduledoc """
  Searches example-set choices per predictor with categorical TPE.

  First `num_demo_sets` bootstrapped example sets are built from shuffled
  training data. The search space has one categorical dimension per
  predictor: which set's demonstrations that predictor uses. `num_trials`
  joint choices are suggested by `Tune.Optimizers.TPE`, uniform for
  the first `n_startup` trials and modeled from validation scores afterward.
  Each trial is a full validation evaluation; repeated choices reuse their
  earlier score without new calls. The best complete eligible trial is
  returned.

  The name identifies the DSPy optimizer family; no Optuna runtime is used.
  Difference from DSPy: DSPy suggests one demonstration index per predictor
  from a single bootstrap; this implementation chooses among whole bootstrapped
  sets per predictor, which keeps demonstrations from one trajectory together.

  Options: `:num_demo_sets` (default 4), `:num_trials` (default 16),
  `:n_startup` (default 4), and BootstrapFewShot options (`:accept_score`
  required).
  """

  @behaviour Tune.Search.ProgramStrategy

  alias Tune.Optimizers.BootstrapFewShot
  alias Tune.Optimizers.BootstrapFewShotWithRandomSearch
  alias Tune.Optimizers.ExampleSets
  alias Tune.Optimizers.Shared
  alias Tune.Optimizers.TPE
  alias Tune.Search.Program.Context

  @fields [
    num_demo_sets: Zoi.integer() |> Zoi.positive() |> Zoi.default(4),
    num_trials: Zoi.integer() |> Zoi.positive() |> Zoi.default(16),
    n_startup: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(4)
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
    do: %{datasets: [:train, :validation], roles: [:teacher], model_calls?: true}

  @impl true
  def compile(config, program, %Context{} = ctx) do
    {sets, ctx} = ExampleSets.bootstrap_sets(config, program, ctx, config.num_demo_sets)

    names = Enum.map(Shared.predictors(program), &elem(&1, 0))

    demo_sets =
      Enum.map(sets, fn candidate ->
        Map.new(Shared.predictors(candidate), fn {n, p} -> {n, p.demos} end)
      end)

    if demo_sets == [] do
      Context.best(Context.stop(ctx, :budget_exhausted))
    else
      ctx = Context.note(ctx, :demo_sets, length(demo_sets))
      tpe = TPE.new(Map.new(names, &{&1, length(demo_sets)}), n_startup: config.n_startup)
      ctx = trials(config, program, demo_sets, tpe, ctx, [], %{}, config.num_trials)
      Context.best(ctx)
    end
  end

  @doc false
  def apply_choice(program, demo_sets, choice) do
    demos =
      Map.new(choice, fn {name, index} -> {name, Map.fetch!(Enum.at(demo_sets, index), name)} end)

    Shared.put_demos(program, demos)
  end

  defp trials(_config, _program, _sets, _tpe, ctx, observations, _cache, 0),
    do: Context.note(ctx, :trials, Enum.reverse(observations))

  defp trials(config, program, sets, tpe, ctx, observations, cache, left) do
    if Context.exhausted?(ctx) do
      ctx |> Context.stop(:budget_exhausted) |> Context.note(:trials, Enum.reverse(observations))
    else
      {choice, ctx} = TPE.suggest(tpe, Enum.reverse(observations), ctx)

      case Map.fetch(cache, choice) do
        {:ok, score} ->
          trials(
            config,
            program,
            sets,
            tpe,
            ctx,
            [{choice, score} | observations],
            cache,
            left - 1
          )

        :error ->
          candidate = apply_choice(program, sets, choice)
          {evaluation, ctx} = Context.evaluate_validation(ctx, candidate)
          {_id, ctx} = Context.consider(ctx, candidate, evaluation, %{choice: choice})

          if evaluation.complete? do
            score =
              evaluation.selected_score || Tune.Evaluation.mean(evaluation) || ctx.failure_score ||
                0

            trials(
              config,
              program,
              sets,
              tpe,
              ctx,
              [{choice, score} | observations],
              Map.put(cache, choice, score),
              left - 1
            )
          else
            ctx
            |> Context.stop(:budget_exhausted)
            |> Context.note(:trials, Enum.reverse(observations))
          end
      end
    end
  end
end
