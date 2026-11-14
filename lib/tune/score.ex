defmodule Tune.Score do
  @moduledoc "A configurable score extension used by `Tune.score/4`."

  @callback score(struct(), Tune.Case.t(), term()) ::
              number()
              | map()
              | {:ok, number() | map()}
              | {:error, term()}
              | {:error, term(), map()}

  @callback model_calls?(struct()) :: boolean()

  @optional_callbacks model_calls?: 1
end
