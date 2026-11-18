defmodule Tune.UI.Study do
  @moduledoc "A data-only description of one workbench study."

  alias Tune.Input
  alias Tune.UI.Registry

  @enforce_keys [:id, :name, :recipe]
  defstruct [:id, :name, :recipe, :inserted_at, :updated_at, config: %{}, data: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          recipe: String.t(),
          config: map(),
          data: %{optional(:train | :validation | :test) => [term()]},
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @fields %{
    name: Input.nonblank_string(),
    recipe: Input.nonblank_string(),
    config: Zoi.map() |> Zoi.nullable() |> Zoi.optional(),
    data: Zoi.map() |> Zoi.nullable() |> Zoi.optional()
  }
  @new Zoi.map(Map.put(@fields, :id, Input.nonblank_string() |> Zoi.nullable() |> Zoi.optional()))
  @update Zoi.map(Map.new(@fields, fn {key, rule} -> {key, Zoi.optional(rule)} end))
  @splits [:train, :validation, :test]
  @data Zoi.map(Map.new(@splits, &{&1, Zoi.array(Zoi.any()) |> Zoi.max(1_000) |> Zoi.optional()}))

  @doc false
  @spec new(map()) :: {:ok, t()} | {:error, Exception.t()}
  def new(attrs) when is_map(attrs) do
    fields = Input.fields(attrs, [:id | Map.keys(@fields)])

    with {:ok, fields} <- Input.definition(@new, fields, "study"),
         {:ok, config} <- recipe_input(fields.recipe, :normalize_config, fields[:config] || %{}),
         {:ok, data} <- normalize_data(fields.recipe, fields[:data] || %{}) do
      now = DateTime.utc_now()

      {:ok,
       %__MODULE__{
         id: fields[:id] || "study-#{System.unique_integer([:positive, :monotonic])}",
         name: String.trim(fields.name),
         recipe: fields.recipe,
         config: config,
         data: data,
         inserted_at: now,
         updated_at: now
       }}
    end
  end

  @doc false
  @spec update(t(), map()) :: {:ok, t()} | {:error, Exception.t()}
  def update(%__MODULE__{} = study, attrs) when is_map(attrs) do
    fields = Map.take(attrs, Map.keys(@fields))

    with {:ok, fields} <- Input.definition(@update, fields, "study"),
         recipe = Map.get(fields, :recipe, study.recipe),
         {:ok, config} <-
           updated(study, fields, :config, recipe, &recipe_input(&1, :normalize_config, &2)),
         {:ok, data} <- updated(study, fields, :data, recipe, &normalize_data/2) do
      {:ok,
       %{
         study
         | name: String.trim(Map.get(fields, :name, study.name)),
           recipe: recipe,
           config: config,
           data: data,
           updated_at: DateTime.utc_now()
       }}
    end
  end

  defp updated(study, fields, key, recipe, normalize) do
    previous = Map.fetch!(study, key)

    cond do
      Map.has_key?(fields, key) -> normalize.(recipe, fields[key] || %{})
      recipe != study.recipe -> normalize.(recipe, previous)
      true -> {:ok, previous}
    end
  end

  defp normalize_data(recipe, input) do
    with {:ok, data} <- Input.definition(@data, Input.fields(input, @splits), "study data") do
      recipe_input(recipe, :normalize_data, data)
    end
  end

  defp recipe_input(id, callback, value) do
    with {:ok, recipe} <- Registry.fetch(id),
         true <- function_exported?(recipe, callback, 1) do
      apply(recipe, callback, [value])
    else
      _ -> {:ok, value}
    end
  end
end
