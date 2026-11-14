defmodule Tune.Metric do
  @moduledoc """
  A normalized metric.

  A metric function receives an `Example` and a successful `Result` and returns
  a finite number or `%{score: number, feedback: binary | nil}`. Higher scores
  are better. There is no range restriction and no rescaling. Invalid returns
  and raised exceptions are row errors.
  """

  alias Tune.Error
  alias Tune.Example
  alias Tune.Result

  @enforce_keys [:fun]
  defstruct [:fun]

  @type t :: %__MODULE__{fun: (Example.t(), Result.t() -> term())}
  @type score :: %{score: number(), feedback: String.t() | nil}

  @doc "Normalizes a metric function or an existing metric."
  @spec new(t() | (Example.t(), Result.t() -> term())) :: {:ok, t()} | {:error, Exception.t()}
  def new(%__MODULE__{} = metric), do: {:ok, metric}
  def new(fun) when is_function(fun, 2), do: {:ok, %__MODULE__{fun: fun}}

  def new(other),
    do:
      {:error,
       Error.Invalid.Option.exception(
         option: :metric,
         message: "must be a 2-arity function, got: #{inspect(other)}"
       )}

  @doc "Scores one result. Returns a normalized score or a metric error."
  @spec score(t(), Example.t(), Result.t()) :: {:ok, score()} | {:error, Exception.t()}
  def score(%__MODULE__{fun: fun}, %Example{} = example, %Result{} = result) do
    fun.(example, result)
  rescue
    error -> metric_error("the metric raised: #{Exception.message(error)}", error)
  catch
    kind, reason -> metric_error("the metric exited: #{inspect({kind, reason})}", reason)
  else
    value -> normalize(value)
  end

  @doc false
  @spec normalize(term()) :: {:ok, score()} | {:error, Exception.t()}
  def normalize(score) when is_number(score), do: {:ok, %{score: score, feedback: nil}}

  def normalize(%{score: score} = value) when is_number(score) do
    case Map.get(value, :feedback) do
      feedback when is_nil(feedback) or is_binary(feedback) ->
        {:ok, %{score: score, feedback: feedback}}

      other ->
        metric_error("metric feedback must be a string or nil", other)
    end
  end

  def normalize(other),
    do: metric_error("the metric must return a number or %{score: number, feedback: text}", other)

  defp metric_error(message, value),
    do: {:error, Error.Execution.Callback.exception(message: message, value: value)}
end
