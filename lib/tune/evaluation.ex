defmodule Tune.Evaluation do
  @moduledoc """
  The eager result of evaluating one target over one dataset.

  `observations` keeps every attempted, failed, interrupted, and skipped case.
  `summaries` keeps raw statistics for each named score. `selected_score` is
  the higher-is-better value that search strategies compare.
  """

  defstruct observations: [],
            summaries: %{},
            selected_score: nil,
            eligible?: false,
            complete?: false,
            calls: %{},
            usage: %{input: 0, output: 0, total: 0},
            metadata: %{},
            stop_reason: :completed

  @type t :: %__MODULE__{
          observations: [Tune.Observation.t()],
          summaries: %{optional(atom()) => Tune.Score.Summary.t()},
          selected_score: number() | nil,
          eligible?: boolean(),
          complete?: boolean(),
          calls: %{optional(atom()) => non_neg_integer()},
          usage: %{input: non_neg_integer(), output: non_neg_integer(), total: non_neg_integer()},
          metadata: map(),
          stop_reason:
            :completed
            | :case_limit
            | :model_call_limit
            | :deadline
            | :cancelled
            | :lost_accounting
        }

  @doc "Starts an evaluation under the caller's Task.Supervisor."
  @spec start(GenServer.server(), Tune.t(), :train | :validation | :test) :: Task.t()
  def start(supervisor, pipeline, role \\ :test) do
    Task.Supervisor.async_nolink(supervisor, fn -> Tune.evaluate(pipeline, role) end)
  end

  @doc "Returns the summary for one named score."
  @spec summary(t(), atom()) :: Tune.Score.Summary.t() | nil
  def summary(%__MODULE__{summaries: summaries}, name), do: Map.get(summaries, name)

  @doc false
  @spec mean(t(), atom()) :: number() | nil
  def mean(%__MODULE__{} = evaluation, name \\ :objective) do
    case summary(evaluation, name) do
      nil -> nil
      value -> value.mean
    end
  end

  @doc false
  @spec coverage(t(), atom()) :: float()
  def coverage(%__MODULE__{} = evaluation, name \\ :objective) do
    case summary(evaluation, name) do
      nil -> 0.0
      value -> value.coverage
    end
  end
end
