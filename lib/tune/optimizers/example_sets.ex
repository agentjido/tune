defmodule Tune.Optimizers.ExampleSets do
  @moduledoc false

  alias Tune.Optimizers.BootstrapFewShot
  alias Tune.Optimizers.LabeledFewShot
  alias Tune.Optimizers.Shared
  alias Tune.Search.Context

  @bootstrap_options [:accept_score, :max_bootstrapped_demos, :max_labeled_demos, :max_rounds]

  @spec bootstrap_config(map()) :: map()
  def bootstrap_config(config), do: Map.take(config, @bootstrap_options)

  @doc """
  Builds one candidate of DSPy's random-search sequence by seed:
  `-3` is the unchanged program, `-2` labeled demonstrations, `-1` an
  unshuffled bootstrap, and `0..` bootstraps from shuffled training data with a
  random demonstration count in `1..max_bootstrapped_demos`.
  """
  @spec build(integer(), map(), Tune.t(), Context.t()) ::
          {:ok, String.t(), Tune.t(), Context.t()} | {:error, Context.t()}
  def build(-3, _config, program, ctx), do: {:ok, "zero_shot", program, ctx}

  def build(-2, config, program, ctx) do
    boot = bootstrap_config(config)

    {labeled, ctx} =
      LabeledFewShot.build(%{k: boot.max_labeled_demos, sample: true}, program, ctx.trainset, ctx)

    {:ok, "labeled", Shared.put_demos(program, labeled), ctx}
  end

  def build(-1, config, program, ctx) do
    case BootstrapFewShot.build(bootstrap_config(config), program, ctx.trainset, ctx) do
      {:ok, candidate, ctx} -> {:ok, "bootstrap", candidate, ctx}
      {:error, _error, ctx} -> {:error, ctx}
    end
  end

  def build(seed, config, program, ctx) when seed >= 0 do
    boot = bootstrap_config(config)
    {train, ctx} = Context.shuffle(ctx, ctx.trainset)
    {size, ctx} = Context.uniform(ctx, max(boot.max_bootstrapped_demos, 1))

    case BootstrapFewShot.build(%{boot | max_bootstrapped_demos: size + 1}, program, train, ctx) do
      {:ok, candidate, ctx} -> {:ok, "bootstrap_#{seed}", candidate, ctx}
      {:error, _error, ctx} -> {:error, ctx}
    end
  end

  @doc "Builds up to `count` bootstrapped sets: unshuffled first, then shuffled."
  @spec bootstrap_sets(map(), Tune.t(), Context.t(), pos_integer()) ::
          {[Tune.t()], Context.t()}
  def bootstrap_sets(config, program, ctx, count) do
    Enum.reduce_while(-1..(count - 2)//1, {[], ctx}, fn seed, {acc, ctx} ->
      if Context.exhausted?(ctx) do
        {:halt, {acc, ctx}}
      else
        case build(seed, config, program, ctx) do
          {:ok, _label, candidate, ctx} -> {:cont, {acc ++ [candidate], ctx}}
          {:error, ctx} -> {:halt, {acc, ctx}}
        end
      end
    end)
  end
end
