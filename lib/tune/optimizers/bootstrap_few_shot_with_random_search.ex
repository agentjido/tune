defmodule Tune.Optimizers.BootstrapFewShotWithRandomSearch do
  @moduledoc """
  Builds several seeded example sets and keeps the best validation result.

  Candidates follow DSPy's order: the unchanged program, labeled
  demonstrations, an unshuffled bootstrap, then `num_candidate_programs`
  bootstraps from shuffled training data with a random demonstration count.
  Each candidate is evaluated on the full validation set; only a complete,
  eligible evaluation can become the incumbent, and ties keep the earlier
  candidate. On the call limit the best completed incumbent is returned with
  `complete?: false`.

  Options: `:num_candidate_programs` (default 8) and the BootstrapFewShot
  options (`:accept_score` required).
  """

  @behaviour Tune.Search.ProgramStrategy

  alias Tune.Optimizers.BootstrapFewShot
  alias Tune.Optimizers.ExampleSets
  alias Tune.Optimizers.Shared
  alias Tune.Search.Program.Context

  @fields [
    num_candidate_programs: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(8)
  ]
  @options Zoi.keyword(@fields, unrecognized_keys: :error)

  @impl true
  def init(opts) do
    {own, boot} = Keyword.split(opts, Keyword.keys(@fields))

    with {:ok, own} <- Shared.options(@options, own),
         {:ok, boot} <- BootstrapFewShot.init(boot),
         :ok <- require_accept(boot) do
      {:ok, Map.merge(boot, own)}
    end
  end

  @impl true
  def requirements(_config),
    do: %{datasets: [:train, :val], roles: [:teacher], model_calls?: true}

  @impl true
  def compile(config, program, %Context{} = ctx) do
    seeds = Enum.to_list(-3..(config.num_candidate_programs - 1)//1)

    ctx =
      Enum.reduce_while(seeds, ctx, fn seed, ctx ->
        with false <- Context.exhausted?(ctx),
             {:ok, label, candidate, ctx} <- ExampleSets.build(seed, config, program, ctx) do
          {evaluation, ctx} = Context.evaluate_validation(ctx, candidate)
          {_id, ctx} = Context.consider(ctx, candidate, evaluation, %{label: label, seed: seed})
          {:cont, ctx}
        else
          true -> {:halt, Context.stop(ctx, :budget_exhausted)}
          {:error, ctx} -> {:halt, Context.stop(ctx, :budget_exhausted)}
        end
      end)

    Context.best(ctx)
  end

  @doc false
  def require_accept(%{accept_score: nil}), do: Shared.option_error(:accept_score, "is required")
  def require_accept(_config), do: :ok
end
