defmodule Tune.UI.Study do
  @moduledoc "A data-only description of one workbench study."

  @enforce_keys [:id, :name, :recipe]
  defstruct [:id, :name, :recipe, :inserted_at, :updated_at, config: %{}, data: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          recipe: String.t(),
          config: map(),
          data: %{optional(:train | :validation | :test) => [map()]},
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc false
  @spec new(map()) :: {:ok, t()} | {:error, Exception.t()}
  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now()
    name = value(attrs, :name)
    recipe = value(attrs, :recipe)

    cond do
      not (is_binary(name) and String.trim(name) != "") ->
        invalid("study name is required")

      not (is_binary(recipe) and String.trim(recipe) != "") ->
        invalid("study recipe is required")

      true ->
        {:ok,
         %__MODULE__{
           id: value(attrs, :id) || id("study"),
           name: String.trim(name),
           recipe: recipe,
           config: value(attrs, :config) || %{},
           data: value(attrs, :data) || %{},
           inserted_at: now,
           updated_at: now
         }}
    end
  end

  @doc false
  @spec update(t(), map()) :: {:ok, t()} | {:error, Exception.t()}
  def update(%__MODULE__{} = study, attrs) when is_map(attrs) do
    study
    |> Map.from_struct()
    |> Map.merge(Map.take(attrs, [:name, :recipe, :config, :data]))
    |> new()
    |> case do
      {:ok, updated} ->
        {:ok,
         %{
           updated
           | id: study.id,
             inserted_at: study.inserted_at,
             updated_at: DateTime.utc_now()
         }}

      error ->
        error
    end
  end

  defp value(attrs, key), do: Map.get(attrs, key, Map.get(attrs, to_string(key)))

  defp id(prefix),
    do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

  defp invalid(message),
    do: {:error, Tune.Error.Invalid.Definition.exception(message: message)}
end
