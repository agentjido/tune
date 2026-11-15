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
    :finished_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          study_id: String.t(),
          mode: :evaluate | :tune,
          status: :queued | :running | :completed | :failed,
          result: Tune.Evaluation.t() | Tune.Result.t() | nil,
          artifact: Tune.Artifact.t() | nil,
          error: term(),
          inserted_at: DateTime.t(),
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil
        }
end
