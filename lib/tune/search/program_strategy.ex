defmodule Tune.Search.ProgramStrategy do
  @moduledoc """
  An internal program-search algorithm.

  An optimizer validates its own configuration, declares which datasets,
  model roles, and limits it needs, and compiles a new program from a
  normalized `Tune.Search.Program.Context`. It changes task parameters
  only. Model configurations, the adapter, and dataset roles are fixed by the
  context for the whole run.
  """

  alias Tune.Search.Program.Context

  @type requirements :: %{
          required(:datasets) => [:train | :validation],
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
  @callback compile(config :: term(), Tune.Program.t(), Context.t()) ::
              {:ok, Tune.Program.t(), Context.t()} | {:error, term(), Context.t()}
end
