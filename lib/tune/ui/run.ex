defmodule Tune.UI.Run do
  @moduledoc "An in-memory workbench run and its current outcome."

  @enforce_keys [:id, :study_id, :mode, :status, :inserted_at]
  defstruct [
    :id,
    :study_id,
    :mode,
    :status,
    :result,
    :artifact,
    :error,
    :inserted_at,
    :started_at,
    :finished_at,
    :source_run_id,
    :study_snapshot,
    :evidence,
    cancel_requested?: false,
    progress: %{rows: 0, candidates: 0, generations: 0}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          study_id: String.t(),
          mode: :evaluate | :tune | :compare,
          status: :queued | :running | :completed | :failed | :cancelled,
          result:
            Tune.Evaluation.t()
            | Tune.Result.t()
            | Tune.Comparison.t()
            | nil,
          artifact: Tune.Artifact.t() | nil,
          error: term(),
          inserted_at: DateTime.t(),
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          source_run_id: String.t() | nil,
          study_snapshot: Tune.UI.Study.t() | nil,
          evidence: map() | nil,
          cancel_requested?: boolean(),
          progress: map()
        }
end
