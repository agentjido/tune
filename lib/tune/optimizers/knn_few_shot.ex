defmodule Tune.Optimizers.KNNFewShot do
  @moduledoc """
  Returns a `Tune.KNN` program whose pool is the training set.

  Compilation makes no model calls. Each later run retrieves the `k` nearest
  training rows for its input and bootstraps demonstrations from them with
  the teacher role, so running the result needs a teacher configuration and
  an explicit `:max_model_calls`, and every teacher call is counted.

  Options: `:k` (default 3), `:max_bootstrapped_demos` (default `k`),
  `:max_labeled_demos` (default 0), `:vectorizer` (function, default bag of
  words).

  Differences from DSPy: no embedding service is called; retrieval uses the
  supplied pure vectorizer. Bootstrapping accepts every successful neighbor
  trajectory, as DSPy does when no metric is given.
  """

  @behaviour Tune.Search.ProgramStrategy

  alias Tune.KNN
  alias Tune.Optimizers.Shared
  alias Tune.Search.Program.Context

  @options Zoi.keyword(
             [
               k: Zoi.integer() |> Zoi.positive() |> Zoi.default(3),
               max_bootstrapped_demos: Zoi.integer() |> Zoi.gte(0),
               max_labeled_demos: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(0),
               vectorizer: Zoi.function(arity: 1) |> Zoi.nullable() |> Zoi.default(nil)
             ],
             unrecognized_keys: :error
           )

  @impl true
  def init(opts) do
    with {:ok, config} <- Shared.options(@options, opts) do
      {:ok, Map.put_new(config, :max_bootstrapped_demos, config.k)}
    end
  end

  @impl true
  def requirements(_config),
    do: %{datasets: [:train], roles: [], model_calls?: false, metric?: false}

  @impl true
  def compile(config, program, %Context{} = ctx) do
    rows = Enum.map(ctx.train, &%{id: &1.id, input: &1.input, expected: &1.expected})

    case KNN.new(program, Map.to_list(config) ++ [pool: rows]) do
      {:ok, knn} -> {:ok, knn, Context.note(ctx, :pool_size, length(rows))}
      {:error, error} -> {:error, error, ctx}
    end
  end
end
