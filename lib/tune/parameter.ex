defmodule Tune.Parameter do
  @moduledoc """
  A tunable JSON value with a Zoi schema, such as a lesson list or candidate text.

  Application code reads it with `Tune.Execution.value/2` and decides
  how to use it. Optimizers replace the value; the schema is code-owned and
  every new value is validated against it.
  """

  alias Tune.Error
  alias Tune.Field

  @enforce_keys [:schema, :value]
  defstruct [:schema, :value, :description]

  @type t :: %__MODULE__{schema: Zoi.schema(), value: term(), description: String.t() | nil}

  @doc """
  Builds a parameter.

  Options: `:schema` (required JSON-compatible Zoi schema), `:value` (required),
  and `:description`.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def new(opts) when is_list(opts) do
    with :ok <- check_keys(opts),
         {:ok, schema} <- fetch(opts, :schema),
         :ok <- Field.check_schema(schema, "parameter"),
         {:ok, value} <- fetch(opts, :value),
         {:ok, value} <- validate(schema, value) do
      {:ok,
       %__MODULE__{schema: schema, value: value, description: Keyword.get(opts, :description)}}
    end
  end

  @doc "Returns the parameter with a new validated value."
  @spec put_value(t(), term()) :: {:ok, t()} | {:error, Exception.t()}
  def put_value(%__MODULE__{schema: schema} = parameter, value) do
    with {:ok, value} <- validate(schema, value) do
      {:ok, %{parameter | value: value}}
    end
  end

  @doc "Validates a value against a parameter schema."
  @spec validate(Zoi.schema(), term()) :: {:ok, term()} | {:error, Exception.t()}
  def validate(schema, value) do
    case Zoi.parse(schema, value) do
      {:ok, parsed} ->
        {:ok, parsed}

      {:error, errors} ->
        {:error,
         Error.Invalid.Definition.exception(
           message: Tune.Signature.format_errors("invalid parameter value", errors),
           details: errors
         )}
    end
  end

  defp check_keys(opts) do
    case Keyword.keys(opts) -- [:schema, :value, :description] do
      [] ->
        :ok

      [key | _] ->
        {:error, Error.Invalid.Option.exception(option: key, message: "unknown parameter option")}
    end
  end

  defp fetch(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, Error.Invalid.Option.exception(option: key, message: "is required")}
    end
  end
end
