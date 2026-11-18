defmodule Tune.TestSupport.Search do
  @moduledoc false

  def run(program, opts) do
    {module, strategy_options} =
      case Keyword.fetch!(opts, :search) do
        {module, config} -> {module, config}
        module -> {module, []}
      end

    pipeline =
      program
      |> Tune.new(Keyword.take(opts, [:model, :teacher, :proposal]))
      |> Tune.data(Keyword.take(opts, [:train, :validation]))
      |> put_score(opts)
      |> Tune.search(module, strategy_options)
      |> Tune.limit(Keyword.take(opts, [:model_calls, :steps, :deadline, :row_timeout, :seed]))

    case Tune.tune(pipeline) do
      {:ok, result} -> {:ok, result.value, result}
      error -> error
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
