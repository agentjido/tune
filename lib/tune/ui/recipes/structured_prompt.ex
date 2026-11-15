defmodule Tune.UI.Recipes.StructuredPrompt do
  @moduledoc "A UI-authored single-predictor Tune recipe."
  @behaviour Tune.UI.Recipe

  alias Tune.UI.Study

  @strategies %{
    "labeled_few_shot" => :labeled_few_shot,
    "bootstrap_few_shot" => :bootstrap_few_shot,
    "bootstrap_few_shot_random_search" => :bootstrap_few_shot_random_search,
    "bootstrap_few_shot_optuna" => :bootstrap_few_shot_optuna,
    "knn_few_shot" => :knn_few_shot,
    "copro" => :copro,
    "signature_optimizer" => :signature_optimizer,
    "mipro_v2" => :mipro_v2,
    "infer_rules" => :infer_rules,
    "simba" => :simba,
    "gepa" => :gepa,
    "avatar" => :avatar,
    "playbook" => :playbook,
    "anything" => :anything,
    "ensemble" => :ensemble
  }

  @adapters %{
    "chat" => Tune.Adapter.Chat,
    "json" => Tune.Adapter.JSON,
    "xml" => Tune.Adapter.XML
  }

  @impl true
  def id, do: "structured_prompt"

  @impl true
  def label, do: "Structured prompt"

  @impl true
  def description, do: "Build and tune one typed predictor from JSON-compatible examples."

  @impl true
  def default_config do
    %{
      "instructions" => "Return the requested structured value.",
      "input_name" => "input",
      "output_name" => "output",
      "output_type" => "string",
      "model" => "openai:gpt-4o-mini",
      "teacher_model" => "",
      "proposal_model" => "",
      "adapter" => "chat",
      "strategy" => "labeled_few_shot",
      "strategy_options" => %{"k" => 4, "sample" => false},
      "limits" => %{"model_calls" => 100, "seed" => 0}
    }
  end

  @impl true
  def build(%Study{} = study) do
    config = Map.merge(default_config(), study.config)

    with {:ok, input_name} <- field_name(config["input_name"], "input"),
         {:ok, output_name} <- field_name(config["output_name"], "output"),
         {:ok, schema} <- output_schema(config["output_type"]),
         {:ok, adapter} <- adapter(config["adapter"]),
         {:ok, strategy} <- strategy(config["strategy"]),
         {:ok, predictor} <-
           Tune.Predictor.new(
             signature: [
               instructions: config["instructions"],
               inputs: [{input_name, Zoi.string()}],
               outputs: [{output_name, schema}]
             ]
           ) do
      pipeline =
        predictor
        |> Tune.new(model_options(config, adapter))
        |> put_data(study.data)
        |> Tune.score(:exact_match, score(output_name), range: {0.0, 1.0})
        |> Tune.search(strategy, option_list(config["strategy_options"]))
        |> Tune.limit(limit_map(config["limits"]))

      {:ok, pipeline}
    end
  rescue
    error -> {:error, error}
  end

  @impl true
  def preview_input(%Study{} = study) do
    study.data
    |> rows_in_order()
    |> Enum.find(&(&1 != []))
    |> case do
      [row | _] ->
        inputs = Map.get(row, "inputs", Map.get(row, :inputs))
        if is_map(inputs), do: {:ok, inputs}, else: invalid("preview row has no inputs map")

      nil ->
        invalid("add at least one data row before preview")
    end
  end

  defp model_options(config, adapter) do
    [model: model(config["model"], adapter)]
    |> put_model(:teacher, config["teacher_model"], adapter)
    |> put_model(:proposal, config["proposal_model"], adapter)
  end

  defp model(id, adapter), do: [model: id, adapter: adapter]

  defp put_model(opts, _role, id, _adapter) when id in [nil, ""], do: opts
  defp put_model(opts, role, id, adapter), do: Keyword.put(opts, role, model(id, adapter))

  defp put_data(pipeline, data) do
    data =
      data
      |> Map.take([:train, :validation, :test])
      |> Map.reject(fn {_k, rows} -> rows == [] end)
      |> Map.new(fn {role, rows} -> {role, Enum.map(rows, &case_row/1)} end)

    if map_size(data) == 0, do: pipeline, else: Tune.data(pipeline, data)
  end

  defp case_row(row) do
    %{
      id: Map.get(row, "id", Map.get(row, :id)),
      input: Map.get(row, "inputs", Map.get(row, :inputs)),
      expected: Map.get(row, "labels", Map.get(row, :labels, %{}))
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp score(output_name) do
    fn example, prediction ->
      if prediction.output[output_name] == example.expected[output_name], do: 1.0, else: 0.0
    end
  end

  defp field_name(value, label) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: invalid("#{label} field name is required"), else: {:ok, value}
  end

  defp field_name(_value, label), do: invalid("#{label} field name must be text")

  defp output_schema("string"), do: {:ok, Zoi.string()}
  defp output_schema("integer"), do: {:ok, Zoi.integer()}
  defp output_schema("float"), do: {:ok, Zoi.float()}
  defp output_schema("boolean"), do: {:ok, Zoi.boolean()}
  defp output_schema(value), do: invalid("unknown output type #{inspect(value)}")

  defp adapter(value) do
    case Map.fetch(@adapters, value) do
      {:ok, module} -> {:ok, module}
      :error -> invalid("unknown adapter #{inspect(value)}")
    end
  end

  defp strategy(value) do
    case Map.fetch(@strategies, value) do
      {:ok, name} -> {:ok, name}
      :error -> invalid("unknown search strategy #{inspect(value)}")
    end
  end

  defp option_list(options) when is_map(options) do
    Enum.map(options, fn {key, value} -> {existing_atom(key), value} end)
  end

  defp option_list(_options), do: []

  defp limit_map(limits) when is_map(limits) do
    Map.new(limits, fn {key, value} -> {existing_atom(key), value} end)
  end

  defp limit_map(_limits), do: %{}

  defp existing_atom(value) when is_atom(value), do: value
  defp existing_atom(value) when is_binary(value), do: String.to_existing_atom(value)

  defp rows_in_order(data),
    do: Enum.map([:test, :validation, :train], &Map.get(data, &1, []))

  defp invalid(message),
    do: {:error, Tune.Error.Invalid.Definition.exception(message: message)}
end
