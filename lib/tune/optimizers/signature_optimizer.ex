defmodule Tune.Optimizers.SignatureOptimizer do
  @moduledoc """
  Searches the instruction of one explicitly named predictor.

  This follows Imp's single-predictor target: it is COPRO's search restricted
  to `:predictor`, and only that predictor's instruction can change. In DSPy,
  `SignatureOptimizer` is a deprecated alias of COPRO; that difference is
  deliberate.

  Options: `:predictor` (required name), `:breadth` (default 4), `:depth`
  (default 2), `:evidence_examples` (default 3).
  """

  @behaviour Tune.Search.ProgramStrategy

  alias Tune.Optimizers.COPRO
  alias Tune.Optimizers.Shared

  @impl true
  def init(opts) do
    case Keyword.pop(opts, :predictor) do
      {name, rest} when is_binary(name) -> COPRO.init(Keyword.put(rest, :predictors, [name]))
      {nil, _rest} -> Shared.option_error(:predictor, "is required")
      {other, _rest} -> Shared.option_error(:predictor, "must be a name, got: #{inspect(other)}")
    end
  end

  @impl true
  def requirements(config), do: COPRO.requirements(config)

  @impl true
  def compile(config, program, ctx), do: COPRO.compile(config, program, ctx)
end
