defmodule Tune.Result do
  @moduledoc "The immutable result of a completed tuning run."

  defstruct value: nil,
            parameters: %{},
            baseline: nil,
            best: nil,
            history: [],
            stop_reason: nil,
            complete?: false,
            calls: %{},
            usage: %{input: 0, output: 0, total: 0},
            metadata: %{}

  @type t :: %__MODULE__{
          value: term(),
          parameters: map(),
          baseline: Tune.Evaluation.t() | nil,
          best: Tune.Candidate.t() | nil,
          history: [Tune.Candidate.t()],
          stop_reason: atom() | nil,
          complete?: boolean(),
          calls: map(),
          usage: map(),
          metadata: map()
        }
end
