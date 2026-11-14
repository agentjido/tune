defmodule Tune.Scores.ContextPrecision do
  @moduledoc "A structured ReqLLM judge for retrieval-context precision."
  @behaviour Tune.Score

  alias Tune.Case
  alias Tune.Score.Judge

  @enforce_keys [:judge]
  defstruct [:judge, timeout: 30_000, concurrency: 3]

  @schema Zoi.object(%{
            "relevant" => Zoi.boolean(),
            "reasoning" => Zoi.string()
          })

  @type t :: %__MODULE__{
          judge: struct(),
          timeout: pos_integer(),
          concurrency: pos_integer()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def new(opts) do
    {score_opts, judge_opts} = Keyword.split(opts, [:timeout, :concurrency])

    with {:ok, judge} <- Judge.new(judge_opts),
         {:ok, timeout} <- positive(score_opts, :timeout, 30_000),
         {:ok, concurrency} <- positive(score_opts, :concurrency, 3) do
      {:ok, %__MODULE__{judge: judge, timeout: timeout, concurrency: concurrency}}
    end
  end

  @impl true
  def score(%__MODULE__{} = score, %Case{} = tune_case, _output) do
    with {:ok, question, contexts, reference} <- fields(tune_case),
         :ok <- require_calls(tune_case, length(contexts)),
         {:ok, results, calls} <- judge_contexts(score, question, contexts, reference) do
      value = average_precision(Enum.map(results, & &1.relevant))

      %{
        score: value,
        feedback: "#{Enum.count(results, & &1.relevant)}/#{length(results)} contexts relevant",
        details: %{contexts: results},
        judge_calls: calls,
        calls: %{judge: length(calls)}
      }
    end
  end

  @impl true
  def model_calls?(%__MODULE__{}), do: true

  defp judge_contexts(score, question, contexts, reference) do
    contexts
    |> Enum.with_index()
    |> Task.async_stream(
      fn {context, index} -> judge_context(score, question, context, reference, index) end,
      ordered: true,
      max_concurrency: score.concurrency,
      timeout: score.timeout,
      on_timeout: :kill_task
    )
    |> Enum.reduce_while({:ok, [], []}, fn
      {:ok, {:ok, result, call}}, {:ok, results, calls} ->
        {:cont, {:ok, [result | results], [call | calls]}}

      {:ok, {:error, error}}, _acc ->
        {:halt, {:error, error}}

      {:exit, reason}, _acc ->
        {:halt, {:error, {:judge_timeout, reason}}}
    end)
    |> then(fn
      {:ok, results, calls} -> {:ok, Enum.reverse(results), Enum.reverse(calls)}
      error -> error
    end)
  end

  defp judge_context(score, question, context, reference, index) do
    prompt = """
    Decide whether the context helps answer the question.

    Question:
    #{question}

    Reference answer:
    #{reference}

    Context:
    #{context}
    """

    with {:ok, object, call} <- Judge.object(score.judge, prompt, @schema, timeout: score.timeout) do
      {:ok,
       %{
         index: index,
         context: context,
         relevant: get(object, :relevant, false),
         reasoning: get(object, :reasoning, "")
       }, call}
    end
  end

  defp fields(%Case{input: input, expected: expected}) when is_map(input) do
    question = get(input, :user_input)
    contexts = get(input, :retrieved_contexts)
    reference = if is_map(expected), do: get(expected, :reference), else: expected

    cond do
      not (is_binary(question) and question != "") -> invalid("user_input is required")
      not (is_list(contexts) and contexts != []) -> invalid("retrieved_contexts are required")
      not (is_binary(reference) and reference != "") -> invalid("reference is required")
      true -> {:ok, question, contexts, reference}
    end
  end

  defp fields(_case), do: invalid("case input must be a map")

  defp average_precision([]), do: 0.0

  defp average_precision(relevance) do
    values =
      relevance
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {relevant?, position} ->
        if relevant? do
          count = relevance |> Enum.take(position) |> Enum.count(& &1)
          [count / position]
        else
          []
        end
      end)

    if values == [], do: 0.0, else: Enum.sum(values) / length(values)
  end

  defp positive(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> invalid("#{key} must be a positive integer")
    end
  end

  defp require_calls(%Case{metadata: metadata}, required) do
    case Map.get(metadata, :model_call_allowance) do
      nil ->
        :ok

      value when value >= required ->
        :ok

      _value ->
        {:error,
         Tune.Error.Execution.LimitReached.exception(
           limit: :model_calls,
           message: "context precision judge call limit reached"
         )}
    end
  end

  defp get(map, key, default \\ nil), do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp invalid(message),
    do: {:error, Tune.Error.Invalid.Input.exception(message: message, errors: [])}
end
