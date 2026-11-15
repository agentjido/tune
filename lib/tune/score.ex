defmodule Tune.Score do
  @moduledoc "One named score declaration and its execution contract."

  alias Tune.Case
  alias Tune.Error
  alias Tune.Prediction

  @enforce_keys [:name, :metric]
  defstruct [:name, :metric, direction: :maximize, range: nil, failure_score: nil]

  @type t :: %__MODULE__{
          name: atom(),
          metric: function() | module() | struct(),
          direction: :maximize | :minimize,
          range: {number(), number()} | nil,
          failure_score: number() | nil
        }

  @callback score(struct(), Tune.Case.t(), term()) ::
              number()
              | map()
              | {:ok, number() | map()}
              | {:error, term()}
              | {:error, term(), map()}

  @callback model_calls?(struct()) :: boolean()

  @optional_callbacks model_calls?: 1

  @doc false
  @spec new!(atom(), function() | module() | struct(), keyword()) :: t()
  def new!(name, metric, opts) when is_atom(name) and is_list(opts) do
    ensure_keys!(opts, [:direction, :range, :failure_score])

    unless supported?(metric) do
      raise ArgumentError, "a score must be a function, module, or Tune.Score struct"
    end

    direction = Keyword.get(opts, :direction, :maximize)
    range = Keyword.get(opts, :range)
    failure_score = Keyword.get(opts, :failure_score)

    if direction not in [:maximize, :minimize] do
      raise ArgumentError, "score direction must be :maximize or :minimize"
    end

    if range != nil and not valid_range?(range) do
      raise ArgumentError, "score range must be {low, high} with high greater than low"
    end

    if failure_score != nil and not is_number(failure_score) do
      raise ArgumentError, "score failure_score must be a number"
    end

    %__MODULE__{
      name: name,
      metric: metric,
      direction: direction,
      range: range,
      failure_score: failure_score
    }
  end

  @doc false
  @spec execute(t(), Case.t(), term(), Prediction.t() | nil) ::
          {:ok, %{score: number(), feedback: String.t() | nil}, map()}
          | {:error, term(), map()}
  def execute(%__MODULE__{metric: metric}, %Case{} = tune_case, output, prediction) do
    value = invoke(metric, tune_case, output, prediction)
    normalize(value)
  rescue
    error ->
      {:error,
       Error.Execution.Callback.exception(
         message: "the score raised: #{Exception.message(error)}",
         value: error
       ), %{}}
  catch
    kind, reason ->
      {:error,
       Error.Execution.Callback.exception(
         message: "the score exited: #{inspect({kind, reason})}",
         value: reason
       ), %{}}
  end

  @doc false
  @spec model_calls?(t()) :: boolean()
  def model_calls?(%__MODULE__{metric: metric}) do
    is_struct(metric) and function_exported?(metric.__struct__, :model_calls?, 1) and
      metric.__struct__.model_calls?(metric)
  end

  @doc false
  @spec valid_range?(term()) :: boolean()
  def valid_range?({low, high}), do: is_number(low) and is_number(high) and high > low
  def valid_range?(_range), do: false

  defp invoke(metric, tune_case, output, prediction) do
    cond do
      is_struct(metric) and function_exported?(metric.__struct__, :score, 3) ->
        metric.__struct__.score(metric, tune_case, output)

      is_function(metric, 2) and prediction ->
        metric.(tune_case, prediction)

      is_function(metric, 2) ->
        metric.(tune_case, output)

      is_function(metric, 1) ->
        metric.(output)

      is_atom(metric) and function_exported?(metric, :score, 2) ->
        metric.score(tune_case, prediction || output)

      true ->
        {:error, "score callback has no supported arity"}
    end
  end

  defp normalize({:ok, value}), do: normalize(value)
  defp normalize({:error, error, metadata}) when is_map(metadata), do: {:error, error, metadata}
  defp normalize({:error, error}), do: {:error, error, %{}}

  defp normalize(%{score: score} = value) when is_number(score) do
    feedback = Map.get(value, :feedback)

    if is_nil(feedback) or is_binary(feedback) do
      metadata = Map.get(value, :metadata, Map.drop(value, [:score, :feedback]))
      {:ok, %{score: score, feedback: feedback}, metadata}
    else
      metric_error("score feedback must be a string or nil", feedback)
    end
  end

  defp normalize(score) when is_number(score),
    do: {:ok, %{score: score, feedback: nil}, %{}}

  defp normalize(other),
    do: metric_error("the score must return a number or %{score: number, feedback: text}", other)

  defp metric_error(message, value),
    do: {:error, Error.Execution.Callback.exception(message: message, value: value), %{}}

  defp supported?(metric) do
    is_function(metric) or is_atom(metric) or
      (is_struct(metric) and function_exported?(metric.__struct__, :score, 3))
  end

  defp ensure_keys!(opts, allowed) do
    case Keyword.keys(opts) -- allowed do
      [] -> :ok
      [key | _] -> raise ArgumentError, "unknown score option #{inspect(key)}"
    end
  end
end
