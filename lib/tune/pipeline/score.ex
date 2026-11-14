defmodule Tune.Pipeline.Score do
  @moduledoc false

  @enforce_keys [:name, :metric]
  defstruct [:name, :metric, direction: :maximize, range: nil, failure_score: nil]

  @type t :: %__MODULE__{
          name: atom(),
          metric: function() | module() | struct(),
          direction: :maximize | :minimize,
          range: Range.t() | {number(), number()} | nil,
          failure_score: number() | nil
        }
end
