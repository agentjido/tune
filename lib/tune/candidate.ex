defmodule Tune.Candidate do
  @moduledoc "A proposed value and its completed evaluation."

  @enforce_keys [:id, :parameters, :value]
  defstruct [:id, :parameters, :value, :evaluation, lineage: %{}, metadata: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          parameters: map(),
          value: term(),
          evaluation: Tune.Evaluation.t() | nil,
          lineage: map(),
          metadata: map()
        }
end
