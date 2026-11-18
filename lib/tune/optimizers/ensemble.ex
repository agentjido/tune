defmodule Tune.Optimizers.Ensemble do
  @moduledoc """
  Builds one compatible ensemble from the pipeline target and explicit members.

  The strategy makes no model calls. `:members` is required. `:size`, `:seed`,
  and `:reducer` have the same meaning as `Tune.Ensemble.new/2`.
  """

  @behaviour Tune.Search.ProgramStrategy

  alias Tune.Optimizers.Shared
  alias Tune.Search.Program.Context

  @options Zoi.keyword(
             [
               members: Zoi.array(Zoi.any()) |> Zoi.min(1) |> Zoi.required(),
               size: Zoi.any(),
               seed: Zoi.any(),
               reducer: Zoi.any()
             ],
             unrecognized_keys: :error
           )

  @impl true
  def init(opts), do: Shared.options(@options, opts)

  @impl true
  def requirements(_config),
    do: %{datasets: [], roles: [], model_calls?: false, metric?: false}

  @impl true
  def compile(config, program, %Context{} = context) do
    opts = config |> Map.drop([:members]) |> Map.to_list()

    case Tune.Ensemble.new([program | config.members], opts) do
      {:ok, ensemble} -> {:ok, ensemble, context}
      {:error, error} -> {:error, error, context}
    end
  end
end
