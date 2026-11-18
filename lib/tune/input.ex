defmodule Tune.Input do
  @moduledoc false

  alias Tune.Error

  def fields(data, keys) do
    Enum.reduce(keys, %{}, fn key, fields ->
      case fetch(data, key) do
        {:ok, value} -> Map.put(fields, key, value)
        :error -> fields
      end
    end)
  end

  def fetch(data, key) do
    case Map.fetch(data, key) do
      :error -> Map.fetch(data, Atom.to_string(key))
      value -> value
    end
  end

  def definition(schema, value, boundary) do
    case Zoi.parse(schema, value) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, errors} -> invalid("#{boundary}: #{format(errors)}", errors)
    end
  end

  def options(schema, opts, boundary, duplicate_policy \\ :last) do
    if Keyword.keyword?(opts) do
      opts = if duplicate_policy == :first, do: Enum.uniq_by(opts, &elem(&1, 0)), else: opts

      case Zoi.parse(schema, opts) do
        {:ok, value} -> {:ok, value}
        {:error, [error | _]} -> option_error(field(error, boundary), error.message)
      end
    else
      option_error(boundary, "expected a keyword list")
    end
  end

  def format(errors), do: Enum.map_join(errors, "; ", &format_error/1)

  def keyword_values, do: Zoi.array(Zoi.tuple({Zoi.atom(), Zoi.any()}))

  def nonblank_string do
    Zoi.string() |> Zoi.refine({__MODULE__, :validate_nonblank, []})
  end

  def validate_nonblank(text, _opts) do
    if String.valid?(text) and String.trim(text) != "",
      do: :ok,
      else: {:error, "must be non-blank UTF-8 text"}
  end

  def invalid(message, details \\ nil),
    do: {:error, Error.Invalid.Definition.exception(message: message, details: details)}

  defp format_error(%{path: [], message: message}), do: message

  defp format_error(%{path: path, message: message}),
    do: "#{Enum.map_join(path, ".", &path_segment/1)} #{message}"

  defp path_segment(key) when is_binary(key) or is_atom(key) or is_integer(key),
    do: to_string(key)

  defp path_segment(key), do: inspect(key)

  defp field(%{path: [key | _]}, _fallback), do: key
  defp field(%{issue: {_message, [key: key]}}, _fallback), do: key
  defp field(_error, fallback), do: fallback

  defp option_error(key, message),
    do: {:error, Error.Invalid.Option.exception(option: key, message: message)}
end
