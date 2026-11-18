defmodule Tune.UI.Recipes.StructuredPrompt do
  @moduledoc "A UI-authored single-predictor Tune recipe."
  @behaviour Tune.UI.Recipe

  alias Tune.Input
  alias Tune.Limits
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

  @config_schema Zoi.map(%{
                   "instructions" => Zoi.string() |> Zoi.nullable(),
                   "input_name" => Input.nonblank_string(),
                   "output_name" => Input.nonblank_string(),
                   "output_type" => Zoi.enum(~w(string integer float boolean)),
                   "model" => Zoi.string(),
                   "teacher_model" => Zoi.string() |> Zoi.nullable(),
                   "proposal_model" => Zoi.string() |> Zoi.nullable(),
                   "adapter" => Zoi.enum(Map.keys(@adapters)),
                   "strategy" => Zoi.enum(Map.keys(@strategies)),
                   "strategy_options" => Zoi.map() |> Zoi.nullable(),
                   "limits" => Zoi.map() |> Zoi.nullable()
                 })
  @row_schema Zoi.map(%{
                inputs: Zoi.map(),
                labels: Zoi.map() |> Zoi.nullable() |> Zoi.optional(),
                id: Zoi.string() |> Zoi.nullable() |> Zoi.optional()
              })

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
  def normalize_config(config) do
    with {:ok, config} <-
           Input.definition(
             @config_schema,
             Map.merge(default_config(), config),
             "prompt settings"
           ),
         {:ok, limits} <- Limits.workbench(config["limits"] || %{}),
         {:ok, options} <- strategy_options(config["strategy_options"] || %{}) do
      {:ok,
       config
       |> Map.update!("input_name", &String.trim/1)
       |> Map.update!("output_name", &String.trim/1)
       |> Map.put("strategy_options", options)
       |> Map.put("limits", limits)}
    end
  end

  @impl true
  def normalize_data(data) do
    Enum.reduce_while(data, {:ok, %{}}, fn {split, rows}, {:ok, acc} ->
      case Tune.UI.RecipeInput.rows(rows, split, &normalize_row/1) do
        {:ok, values} -> {:cont, {:ok, Map.put(acc, split, values)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @impl true
  def build(%Study{config: config} = study) do
    input_name = config["input_name"]
    output_name = config["output_name"]
    schema = output_schema(config["output_type"])
    adapter = Map.fetch!(@adapters, config["adapter"])
    strategy = Map.fetch!(@strategies, config["strategy"])

    with {:ok, predictor} <-
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
        |> Tune.score(:exact_match, score(output_name), argument: :output, range: {0.0, 1.0})
        |> Tune.search(strategy, Map.to_list(config["strategy_options"]))

      {:ok, %{pipeline | limits: config["limits"]}}
    end
  rescue
    error -> {:error, error}
  end

  defp normalize_row(%{} = row) do
    row = Input.fields(row, [:inputs, :labels, :id])
    Input.definition(@row_schema, row, "prompt row")
  end

  defp normalize_row(row), do: Input.definition(@row_schema, row, "prompt row")

  @impl true
  def preview_input(%Study{} = study) do
    study.data
    |> rows_in_order()
    |> Enum.find(&(&1 != []))
    |> case do
      [row | _] ->
        {:ok, row.inputs}

      nil ->
        invalid("add at least one data row before preview")
    end
  end

  defp model_options(config, adapter) do
    [model: model(config["model"], adapter)]
    |> put_model(:teacher, config["teacher_model"], adapter)
    |> put_model(:proposal, config["proposal_model"], adapter)
  end

  defp model(id, Tune.Adapter.JSON),
    do: [model: id, adapter: Tune.Adapter.JSON, adapter_options: [mode: :text]]

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
    fn example, output ->
      if output[output_name] == example.expected[output_name], do: 1.0, else: 0.0
    end
  end

  defp output_schema("string"), do: Zoi.string()
  defp output_schema("integer"), do: Zoi.integer()
  defp output_schema("float"), do: Zoi.float()
  defp output_schema("boolean"), do: Zoi.boolean()

  defp strategy_options(options) do
    {:ok, Map.new(options, fn {key, value} -> {existing_atom(key), value} end)}
  rescue
    ArgumentError -> invalid("unknown strategy option")
  end

  defp existing_atom(value) when is_atom(value), do: value
  defp existing_atom(value) when is_binary(value), do: String.to_existing_atom(value)
  defp existing_atom(_value), do: raise(ArgumentError)

  defp rows_in_order(data),
    do: Enum.map([:test, :validation, :train], &Map.get(data, &1, []))

  defp invalid(message),
    do: {:error, Tune.Error.Invalid.Definition.exception(message: message)}
end
