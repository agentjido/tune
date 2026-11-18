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

  @options Zoi.keyword([predictor: Zoi.string() |> Zoi.required()], unrecognized_keys: :preserve)

  @impl true
  def init(opts) do
    with {:ok, values} <- Tune.Input.options(@options, opts, :optimizer) do
      {name, rest} = Keyword.pop(values, :predictor)
      COPRO.init(Keyword.put(rest, :predictors, [name]))
    end
  end

  @impl true
  def requirements(config), do: COPRO.requirements(config)

  @impl true
  def compile(config, program, ctx), do: COPRO.compile(config, program, ctx)
end
