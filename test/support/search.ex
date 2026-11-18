defmodule Tune.TestSupport.Search do
  @moduledoc false

  def run(program, opts) do
    {module, strategy_options} =
      case Keyword.fetch!(opts, :optimizer) do
        {module, config} -> {module, config}
        module -> {module, []}
      end

    limits =
      for {old, new} <- [
            max_model_calls: :model_calls,
            max_steps: :steps,
            timeout: :deadline,
            row_timeout: :row_timeout,
            seed: :seed
          ],
          Keyword.has_key?(opts, old),
          do: {new, Keyword.fetch!(opts, old)}

    pipeline =
      program
      |> Tune.new(Keyword.take(opts, [:model, :teacher, :proposal]))
      |> put_split(opts, :trainset, :train)
      |> put_split(opts, :valset, :validation)
      |> put_score(opts)
      |> Tune.search(module, strategy_options)
      |> Tune.limit(limits)

    case Tune.tune(pipeline) do
      {:ok, result} -> {:ok, result.value, result}
      error -> error
    end
  end

  defp put_split(pipeline, opts, key, split) do
    case Keyword.fetch(opts, key) do
      {:ok, data} -> Tune.data(pipeline, [{split, data}])
      :error -> pipeline
    end
  end

  defp put_score(pipeline, opts) do
    case Keyword.fetch(opts, :metric) do
      {:ok, metric} ->
        Tune.score(pipeline, :objective, metric, Keyword.take(opts, [:failure_score]))

      :error ->
        pipeline
    end
  end
end
