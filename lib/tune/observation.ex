defmodule Tune.Observation do
  @moduledoc "The scores and outcome for one evaluated case."

  defstruct id: nil,
            status: :ok,
            scores: %{},
            score_errors: %{},
            feedback: %{},
            eligible?: true,
            output: nil,
            prediction: nil,
            error: nil,
            calls: %{},
            metadata: %{}

  @type status :: :ok | :error | :interrupted | :skipped

  @type t :: %__MODULE__{
          id: String.t() | nil,
          status: status(),
          scores: %{optional(atom()) => number()},
          score_errors: map(),
          feedback: %{optional(atom()) => String.t() | nil},
          eligible?: boolean(),
          output: term(),
          prediction: Tune.Prediction.t() | nil,
          error: term(),
          calls: map(),
          metadata: map()
        }
end
