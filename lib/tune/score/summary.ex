defmodule Tune.Score.Summary do
  @moduledoc "The aggregate for one named score."

  @enforce_keys [:name, :direction]
  defstruct [:name, :direction, :count, :mean, :min, :max, :coverage]

  @type t :: %__MODULE__{
          name: atom(),
          direction: :maximize | :minimize,
          count: non_neg_integer(),
          mean: number() | nil,
          min: number() | nil,
          max: number() | nil,
          coverage: float()
        }
end
