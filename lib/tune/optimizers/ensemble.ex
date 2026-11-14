defmodule Tune.Optimizers.Ensemble do
  @moduledoc """
  Builds one compatible ensemble from the pipeline target and explicit members.

  The strategy makes no model calls. `:members` is required. `:size`, `:seed`,
  and `:reducer` have the same meaning as `Tune.Ensemble.new/2`.
  """

  @behaviour Tune.Search.ProgramStrategy

  alias Tune.Error
  alias Tune.Search.Context

  @options [:members, :size, :seed, :reducer]

  @impl true
  def init(opts) do
    unknown = Keyword.keys(opts) -- @options
    members = Keyword.get(opts, :members)

    cond do
      unknown != [] ->
        invalid(hd(unknown), "unknown ensemble option")

      not is_list(members) or members == [] ->
        invalid(:members, "must be a nonempty list of compatible programs")

      true ->
        {:ok, Map.new(opts)}
    end
  end

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

  defp invalid(option, message),
    do: {:error, Error.Invalid.Option.exception(option: option, message: message)}
end
