defmodule Tune.Optimizer do
  @moduledoc """
  A concrete optimization algorithm.

  An optimizer validates its own configuration, declares which datasets,
  model roles, and limits it needs, and compiles a new program from a
  normalized `Tune.Optimizer.Context`. It changes task parameters
  only. Model configurations, the adapter, and dataset roles are fixed by the
  context for the whole run.
  """

  alias Tune.Optimizer.Context

  @type requirements :: %{
          required(:datasets) => [:train | :val],
          required(:roles) => [:teacher | :proposal],
          required(:model_calls?) => boolean(),
          optional(:metric?) => boolean()
        }

  @doc "Validates and normalizes optimizer configuration."
  @callback init(keyword()) :: {:ok, term()} | {:error, Exception.t()}

  @doc "Declares the datasets, roles, and limits the configured algorithm needs."
  @callback requirements(config :: term()) :: requirements()

  @doc """
  Builds a new program. Returns the program and the final context, or an error
  and the final context. The context carries candidates, accounting, and the
  stop reason used for the report.
  """
  @callback compile(config :: term(), Tune.t(), Context.t()) ::
              {:ok, Tune.t(), Context.t()} | {:error, term(), Context.t()}

  defmodule Report do
    @moduledoc """
    The record of one optimization run.

    `complete?` is `true` only when the algorithm finished normally. A limited
    run sets `stop_reason` and never claims completion. `candidates` lists
    every recorded candidate with its evaluation summary and lineage. `best`
    is the returned candidate's summary, or `nil` for builds that were not
    scored. Calls are attempted managed calls per role.
    """

    defstruct [
      :optimizer,
      :complete?,
      :stop_reason,
      :best,
      :seed,
      :max_model_calls,
      candidates: [],
      calls: %{},
      usage: %{input: 0, output: 0, total: 0},
      datasets: %{},
      notes: %{}
    ]

    @type t :: %__MODULE__{
            optimizer: module(),
            complete?: boolean(),
            stop_reason: atom() | nil,
            best: map() | nil,
            seed: integer(),
            max_model_calls: non_neg_integer() | nil,
            candidates: [map()],
            calls: %{optional(atom()) => non_neg_integer()},
            usage: map(),
            datasets: map(),
            notes: map()
          }

    @doc "Returns total attempted managed calls."
    @spec total_calls(t()) :: non_neg_integer()
    def total_calls(%__MODULE__{calls: calls}), do: calls |> Map.values() |> Enum.sum()
  end
end
