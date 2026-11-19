defmodule Tune.UI.Evidence do
  @moduledoc false

  alias Tune.ModelConfig
  alias Tune.Score.Judge
  alias Tune.UI.Store

  def capture(pipeline, study, splits, run_id) do
    Store.update_run(run_id, %{
      evidence: %{
        study_name: study.name,
        recipe: study.recipe,
        splits: splits,
        datasets: %{},
        scores: Enum.map(pipeline.scores, &score/1),
        selector: pipeline.selector,
        models: model_configs(pipeline)
      }
    })

    limits =
      Map.put(pipeline.limits, :on_dataset, fn split, stage, dataset ->
        evidence = Store.get_run(run_id).evidence

        datasets =
          Map.update(evidence.datasets, split, %{stage => dataset}, &Map.put(&1, stage, dataset))

        Store.update_run(run_id, %{evidence: %{evidence | datasets: datasets}})
      end)

    %{pipeline | limits: limits}
  end

  def successful_models(%Tune.Comparison{baseline: baseline, challenger: challenger}) do
    Enum.uniq(successful_models(baseline) ++ successful_models(challenger))
  end

  def successful_models(%{metadata: metadata}), do: Map.get(metadata, :successful_models, [])
  def successful_models(_result), do: []

  defp score(score) do
    score
    |> Map.take([:name, :direction, :range, :failure_score, :argument])
    |> Map.put(:metric, metric_name(score.metric))
  end

  defp metric_name(%module{}), do: inspect(module)
  defp metric_name(module) when is_atom(module), do: inspect(module)

  defp metric_name(callback) do
    {:module, module} = Function.info(callback, :module)
    {:name, name} = Function.info(callback, :name)
    {:arity, arity} = Function.info(callback, :arity)
    "#{inspect(module)}.#{name}/#{arity}"
  end

  def model_configs(pipeline) do
    targets =
      for {role, value} <- pipeline.models, {:ok, config} <- [ModelConfig.new(value)] do
        role = if role == :model, do: :target, else: role
        {to_string(role), model_config(config)}
      end

    judges =
      for %{name: name, metric: %{judge: %Judge{} = judge} = metric} <- pipeline.scores do
        {"judge (#{name})",
         %{
           "model" => judge.model_id,
           "concurrency" => metric.concurrency,
           "timeout" => metric.timeout
         }}
      end

    Map.new(targets ++ judges)
  end

  defp model_config(config) do
    opts =
      for key <- [:temperature, :max_tokens, :top_p, :seed, :total_timeout],
          value = config.request_options[key],
          is_number(value) or value == :infinity,
          into: %{},
          do: {key, value}

    details = ModelConfig.describe(config)

    details =
      if config.adapter in [Tune.Adapter.Chat, Tune.Adapter.JSON, Tune.Adapter.XML],
        do: details,
        else: Map.delete(details, "adapter_options")

    Map.put(details, "generation_options", opts)
  end
end
