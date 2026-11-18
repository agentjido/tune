defmodule Tune.Optimizers.GEPA do
  @moduledoc """
  Reflective prompt evolution with Pareto selection and merge.

  Each predictor instruction is a component of the search in
  `Tune.Optimizers.Reflective`: parents are chosen from the per-row
  validation Pareto frontier, the proposal role reflects on training
  trajectories with scores and metric feedback (score-only metrics work too),
  children must beat their parent on the same training minibatch before a
  full validation pass, and complementary children with a common ancestor
  are merged. Lineage and per-row frontier data are kept in the report.

  Options: `:max_iterations` (default 8), `:minibatch_size` (default 3),
  `:use_merge` (default `true`), `:merge_every` (default 3), and
  `:predictors` (names to evolve; default all).

  Differences from the `gepa` package: budgets are managed model calls rather
  than metric calls; there is no automatic budget preset, experiment
  tracking, or multi-objective metric framework.
  """

  @behaviour Tune.Search.ProgramStrategy

  alias Tune.Optimizers.Proposals
  alias Tune.Optimizers.Reflective
  alias Tune.Optimizers.Shared
  alias Tune.Search.Program.Context

  @fields [predictors: Zoi.array(Zoi.string()) |> Zoi.nullable() |> Zoi.default(nil)]

  @impl true
  def init(opts), do: Shared.options(Reflective.options(@fields), opts)

  @impl true
  def requirements(_config),
    do: %{datasets: [:train, :validation], roles: [:proposal], model_calls?: true}

  @impl true
  def compile(config, program, %Context{} = ctx) do
    predictors = Shared.predictors(program)
    names = config.predictors || Enum.map(predictors, &elem(&1, 0))

    case names -- Enum.map(predictors, &elem(&1, 0)) do
      [] ->
        Reflective.run(
          config,
          program,
          Enum.map(Enum.sort(names), &component(&1, Map.new(predictors))),
          ctx
        )

      unknown ->
        {:error,
         elem(Shared.option_error(:predictors, "unknown predictors: #{inspect(unknown)}"), 1),
         ctx}
    end
  end

  defp component(name, predictors) do
    task = Proposals.describe(Map.fetch!(predictors, name))

    %{
      name: name,
      get: fn program ->
        Map.new(Shared.predictors(program))
        |> Map.fetch!(name)
        |> then(& &1.signature.instructions)
      end,
      put: fn program, text -> Shared.put_instructions(program, %{name => text}) end,
      propose: fn ctx, current, feedback -> Proposals.reflect(ctx, task, current, feedback) end
    }
  end
end
