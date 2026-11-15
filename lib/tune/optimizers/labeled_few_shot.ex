defmodule Tune.Optimizers.LabeledFewShot do
  @moduledoc """
  Uses up to `k` complete labeled training examples as demonstrations for each
  predictor. Makes no model calls.

  An example supplies a demonstration for a predictor when its inputs and
  labels contain every field of that predictor's signature and the values are
  valid. With `sample: true` (the default) examples are sampled without
  replacement using local seeded random state; otherwise the first `k` are used.

  Options: `:k` (default 16), `:sample` (default `true`).

  Differences from DSPy: the build is unscored and returns no validation
  improvement claim; predictors without complete labeled examples keep no demos.
  """

  @behaviour Tune.Search.ProgramStrategy

  alias Tune.Optimizers.Shared
  alias Tune.Search.Program.Context

  @impl true
  def init(opts) do
    with {:ok, opts} <- Shared.require_options(opts, [:k, :sample], k: 16, sample: true),
         :ok <- Shared.non_negative(opts, :k),
         :ok <-
           if(is_boolean(opts[:sample]),
             do: :ok,
             else: Shared.option_error(:sample, "must be a boolean")
           ) do
      {:ok, Map.new(opts)}
    end
  end

  @impl true
  def requirements(_config),
    do: %{datasets: [:train], roles: [], model_calls?: false, metric?: false}

  @impl true
  def compile(config, program, %Context{} = ctx) do
    {demos, ctx} = build(config, program, ctx.trainset, ctx)
    ctx = Context.note(ctx, :demos, Map.new(demos, fn {name, list} -> {name, length(list)} end))
    {:ok, Shared.put_demos(program, demos), ctx}
  end

  @doc false
  @spec build(map(), Tune.t(), [Tune.Case.t()], Context.t()) ::
          {%{String.t() => [Tune.Demo.t()]}, Context.t()}
  def build(%{k: k, sample: sample}, program, examples, ctx) do
    Enum.reduce(Shared.predictors(program), {%{}, ctx}, fn {name, predictor}, {acc, ctx} ->
      candidates =
        Enum.flat_map(examples, fn example ->
          case Shared.labeled_demo(predictor, example) do
            {:ok, demo} -> [demo]
            :error -> []
          end
        end)

      {chosen, ctx} =
        if sample, do: Context.sample(ctx, candidates, k), else: {Enum.take(candidates, k), ctx}

      {Map.put(acc, name, chosen), ctx}
    end)
  end
end
