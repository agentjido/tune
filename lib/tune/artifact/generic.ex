defmodule Tune.Artifact.Generic do
  @moduledoc false

  alias Tune.CanonicalJSON
  alias Tune.Error

  @spec project(map()) :: {:ok, map()} | {:error, Exception.t()}
  def project(parameters) when is_map(parameters) do
    parameters = Map.new(parameters, fn {name, value} -> {to_string(name), value} end)

    if json_safe?(parameters),
      do: {:ok, parameters},
      else:
        {:error,
         Error.Invalid.Option.exception(
           option: :artifact,
           message: "parameters must be JSON data"
         )}
  end

  @spec target_fingerprint(map()) :: String.t()
  def target_fingerprint(parameters) do
    parameters
    |> Map.new(fn {name, value} -> {to_string(name), value_contract(value)} end)
    |> CanonicalJSON.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec apply(map(), map(), String.t()) :: {:ok, map()} | {:error, Exception.t()}
  def apply(fresh_target, parameters, fingerprint) when is_map(fresh_target) do
    fields =
      for {key, value} <- Map.to_list(fresh_target),
          key != :__struct__ and (is_atom(key) or is_binary(key)),
          name = to_string(key),
          is_map_key(parameters, name),
          do: {name, {key, value}}

    available = Map.new(fields)

    with true <- length(fields) == map_size(available),
         true <- map_size(available) == map_size(parameters),
         true <- target_fingerprint(parameters) == fingerprint,
         current = Map.new(available, fn {name, {_key, value}} -> {name, value} end),
         true <- target_fingerprint(current) == fingerprint do
      {:ok,
       Enum.reduce(parameters, fresh_target, fn {name, value}, target ->
         {key, _old} = Map.fetch!(available, name)
         Map.put(target, key, value)
       end)}
    else
      false -> invalid("artifact parameters do not match the fresh target")
    end
  end

  def apply(_fresh_target, _parameters, _fingerprint),
    do: invalid("a generic artifact requires a map or struct target")

  @spec genome_fingerprint(term()) :: String.t()
  def genome_fingerprint(value) do
    type =
      cond do
        is_map(value) and not is_struct(value) -> "map"
        is_list(value) -> "list"
        true -> value_contract(value)
      end

    :crypto.hash(:sha256, type) |> Base.encode16(case: :lower)
  end

  @spec apply_genome(term(), map(), String.t()) :: {:ok, term()} | {:error, Exception.t()}
  def apply_genome(fresh_target, %{"genome" => replacement}, fingerprint) do
    if genome_fingerprint(fresh_target) == fingerprint and
         genome_fingerprint(replacement) == fingerprint,
       do: {:ok, replacement},
       else: invalid("artifact genome does not match the fresh target type")
  end

  defp value_contract(value) when is_integer(value), do: "integer"
  defp value_contract(value) when is_float(value), do: "float"
  defp value_contract(value) when is_binary(value), do: "string"
  defp value_contract(value) when is_boolean(value), do: "boolean"
  defp value_contract(nil), do: "null"

  defp value_contract(value) when is_list(value) do
    %{"list" => value |> Enum.map(&value_contract/1) |> Enum.uniq() |> Enum.sort()}
  end

  defp value_contract(value) when is_map(value) and not is_struct(value) do
    %{"map" => Map.new(value, fn {key, item} -> {to_string(key), value_contract(item)} end)}
  end

  defp value_contract(_value), do: "unsupported"

  defp json_safe?(value) when is_map(value) and not is_struct(value),
    do: Enum.all?(value, fn {key, item} -> is_binary(key) and json_safe?(item) end)

  defp json_safe?(value) when is_list(value), do: Enum.all?(value, &json_safe?/1)

  defp json_safe?(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: true

  defp json_safe?(_value), do: false

  defp invalid(message), do: {:error, Error.Invalid.Definition.exception(message: message)}
end
