defmodule Tune.UI.Registry do
  @moduledoc "Resolves workbench recipe IDs to trusted application modules."

  @built_in [Tune.UI.Recipes.StructuredPrompt, Tune.UI.Recipes.SavedResponses]

  @doc "Lists the configured recipe modules."
  @spec all() :: [module()]
  def all do
    configured = Application.get_env(:tune, Tune.UI, []) |> Keyword.get(:recipes, [])

    (@built_in ++ configured)
    |> Enum.uniq()
    |> Enum.filter(&valid?/1)
  end

  @doc "Returns a trusted recipe module by its stable ID."
  @spec fetch(String.t()) :: {:ok, module()} | {:error, Exception.t()}
  def fetch(id) when is_binary(id) do
    case Enum.find(all(), &(&1.id() == id)) do
      nil ->
        {:error,
         Tune.Error.Invalid.Definition.exception(message: "unknown Tune UI recipe #{inspect(id)}")}

      module ->
        {:ok, module}
    end
  end

  defp valid?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and
      Enum.all?(
        [id: 0, label: 0, description: 0, default_config: 0, build: 1, preview_input: 1],
        fn
          {name, arity} -> function_exported?(module, name, arity)
        end
      )
  end
end
