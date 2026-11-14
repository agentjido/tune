defmodule Tune.Case do
  @moduledoc "One normalized input and expected result."

  @enforce_keys [:id, :input]
  defstruct [:id, :input, :expected, metadata: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          input: term(),
          expected: term(),
          metadata: map()
        }
end
