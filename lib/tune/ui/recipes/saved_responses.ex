defmodule Tune.UI.Recipes.SavedResponses do
  @moduledoc "Scores a saved single-turn dataset with both retrieval judges."
  @behaviour Tune.UI.Recipe

  alias Tune.Input
  alias Tune.Limits
  alias Tune.Replay

  @schema Zoi.map(%{
            "model" => Zoi.string(),
            "strategy_options" => Zoi.map() |> Zoi.nullable(),
            "limits" => Zoi.map() |> Zoi.nullable()
          })

  @impl true
  def id, do: "saved_responses"

  @impl true
  def label, do: "Saved responses"

  @impl true
  def description, do: "Score saved answers for faithfulness and context precision."

  @impl true
  def default_config do
    %{
      "model" => "openai:gpt-4o-mini",
      "strategy_options" => %{},
      "limits" => %{"model_calls" => 100}
    }
  end

  @impl true
  def normalize_config(config) do
    with {:ok, config} <-
           Input.definition(
             @schema,
             Map.merge(default_config(), config),
             "saved response settings"
           ),
         {:ok, limits} <- Limits.workbench(config["limits"] || %{}) do
      {:ok, Map.put(config, "limits", Map.put_new(limits, :model_calls, 100))}
    end
  end

  @impl true
  def normalize_data(%{test: rows} = data) do
    with {:ok, rows} <- Tune.UI.RecipeInput.rows(Replay.legacy_rows(rows), :test, &Replay.parse/1) do
      {:ok, %{data | test: rows}}
    end
  end

  def normalize_data(data), do: {:ok, data}

  @impl true
  def build(study) do
    judge = [model: study.config["model"]]

    with {:ok, faithfulness} <- Tune.Scores.Faithfulness.new(judge),
         {:ok, precision} <- Tune.Scores.ContextPrecision.new(judge) do
      limits =
        Map.take(study.config["limits"], [
          :model_calls,
          :cases,
          :deadline,
          :row_timeout,
          :row_calls,
          :concurrency
        ])

      pipeline =
        Map.get(study.data, :test, [])
        |> Tune.replay()
        |> Tune.score(:faithfulness, faithfulness)
        |> Tune.score(:context_precision, precision)

      {:ok, %{pipeline | limits: limits}}
    end
  end

  @impl true
  def preview_input(_study) do
    {:error,
     Tune.Error.Invalid.Option.exception(
       option: :preview,
       message: "saved responses have no target prompt"
     )}
  end
end
