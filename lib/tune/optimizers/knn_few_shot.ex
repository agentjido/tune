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

  @impl true
  def init(opts) do
    with {:ok, opts} <-
           Shared.require_options(
             opts,
             [:k, :max_bootstrapped_demos, :max_labeled_demos, :vectorizer],
             k: 3,
             max_labeled_demos: 0,
             vectorizer: nil
           ),
         opts = Keyword.put_new(opts, :max_bootstrapped_demos, opts[:k]),
         :ok <-
           Shared.with_checks([
             fn -> Shared.positive(opts, :k) end,
             fn -> Shared.non_negative(opts, :max_bootstrapped_demos) end,
             fn -> Shared.non_negative(opts, :max_labeled_demos) end,
             fn ->
               if is_nil(opts[:vectorizer]) or is_function(opts[:vectorizer], 1),
                 do: :ok,
                 else: Shared.option_error(:vectorizer, "must be a 1-arity function")
             end
           ]) do
      {:ok, Map.new(opts)}
    end
  end

  @impl true
  def requirements(_config),
    do: %{datasets: [:train], roles: [], model_calls?: false, metric?: false}

  @impl true
  def compile(config, program, %Context{} = ctx) do
    rows = Enum.map(ctx.trainset, &%{id: &1.id, input: &1.input, expected: &1.expected})

    case KNN.new(program, Map.to_list(config) ++ [pool: rows]) do
      {:ok, knn} -> {:ok, knn, Context.note(ctx, :pool_size, length(rows))}
      {:error, error} -> {:error, error, ctx}
    end
  end
end
