defmodule Tune.Score do
  @moduledoc "One named score declaration and its execution contract."

  alias Tune.Case
  alias Tune.Error
  alias Tune.Input
  alias Tune.Prediction

  @enforce_keys [:name, :metric]
  defstruct [
    :name,
    :metric,
    direction: :maximize,
    range: nil,
    failure_score: nil,
    argument: :output
  ]

  @type t :: %__MODULE__{
          name: atom(),
          metric: function() | module() | struct(),
          direction: :maximize | :minimize,
          range: {number(), number()} | nil,
          failure_score: number() | nil,
          argument: :output | :prediction
        }

  @options Zoi.keyword(
             [
               direction: Zoi.enum([:maximize, :minimize]) |> Zoi.default(:maximize),
               range: Zoi.tuple({Zoi.number(), Zoi.number()}) |> Zoi.nullable(),
               failure_score: Zoi.number() |> Zoi.nullable(),
               argument: Zoi.enum([:output, :prediction]) |> Zoi.default(:output)
             ],
             unrecognized_keys: :error
           )

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
    unless supported?(metric) do
      raise ArgumentError, "a score must be a function, module, or Tune.Score struct"
    end

    opts =
      case Input.options(@options, opts, :score, :first) do
        {:ok, values} -> values
        {:error, error} -> raise ArgumentError, Exception.message(error)
      end

    range = opts[:range]
    argument = opts[:argument]

    if argument == :prediction and not (is_function(metric, 2) or is_atom(metric)) do
      raise ArgumentError, "score argument applies to two-argument scorers"
    end

    if range != nil and not valid_range?(range) do
      raise ArgumentError, "score range must be {low, high} with high greater than low"
    end

    %__MODULE__{
      name: name,
      metric: metric,
      direction: opts[:direction],
      range: range,
      failure_score: opts[:failure_score],
      argument: argument
    }
  end

  @doc false
  @spec execute(t(), Case.t(), term(), Prediction.t() | nil) ::
          {:ok, %{score: number(), feedback: String.t() | nil}, map()}
          | {:error, term(), map()}
  def execute(%__MODULE__{} = score, %Case{} = tune_case, output, prediction) do
    value = invoke(score.metric, tune_case, output, score_argument(score, output, prediction))
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

  defp score_argument(%{argument: :output}, output, _prediction), do: output
  defp score_argument(%{argument: :prediction}, _output, prediction), do: prediction

  defp invoke(metric, tune_case, output, argument) do
    cond do
      is_struct(metric) and function_exported?(metric.__struct__, :score, 3) ->
        metric.__struct__.score(metric, tune_case, output)

      is_function(metric, 2) ->
        metric.(tune_case, argument)

      is_function(metric, 1) ->
        metric.(output)

      is_atom(metric) and function_exported?(metric, :score, 2) ->
        metric.score(tune_case, argument)

      true ->
        {:error, "score callback has no supported arity"}
    end
  end

  defp normalize({:ok, value}), do: normalize(value)
  defp normalize({:error, error, metadata}), do: with_metadata(:error, error, metadata)
  defp normalize({:error, error}), do: {:error, error, %{}}

  defp normalize(%{score: score} = value) when is_number(score) do
    feedback = Map.get(value, :feedback)

    if is_nil(feedback) or is_binary(feedback) do
      metadata = Map.get(value, :metadata, Map.drop(value, [:score, :feedback]))
      with_metadata(:ok, %{score: score, feedback: feedback}, metadata)
    else
      metric_error("score feedback must be a string or nil", feedback)
    end
  end

  defp normalize(score) when is_number(score),
    do: {:ok, %{score: score, feedback: nil}, %{}}

  defp normalize(other),
    do: metric_error("the score must return a number or %{score: number, feedback: text}", other)

  defp with_metadata(status, value, metadata) do
    if valid_metadata?(metadata),
      do: {status, value, metadata},
      else: metric_error("score metadata has invalid call evidence", metadata)
  end

  defp valid_metadata?(metadata) when is_map(metadata) do
    calls = Map.get(metadata, :calls, %{})
    judges = Map.get(metadata, :judge_calls, [])

    is_map(calls) and not is_struct(calls) and
      Enum.all?(calls, fn {_role, count} -> is_integer(count) and count >= 0 end) and
      is_list(judges) and Enum.all?(judges, &valid_judge_call?/1)
  end

  defp valid_metadata?(_metadata), do: false

  defp valid_judge_call?(call) when is_map(call) and not is_struct(call) do
    usage = Map.get(call, :usage)
    is_nil(usage) or is_map(usage)
  end

  defp valid_judge_call?(_call), do: false

  defp metric_error(message, value),
    do: {:error, Error.Execution.Callback.exception(message: message, value: value), %{}}

  defp supported?(metric) do
    is_function(metric) or is_atom(metric) or
      (is_struct(metric) and function_exported?(metric.__struct__, :score, 3))
  end
end
