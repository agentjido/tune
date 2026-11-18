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
    with {:ok, fields} <- Judge.configure(opts) do
      {:ok, struct!(__MODULE__, fields)}
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
    else
      {:error, error, calls} -> {:error, error, Judge.evidence(calls)}
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  def model_calls?(%__MODULE__{}), do: true

  defp judge_contexts(score, question, contexts, reference) do
    Judge.collect(
      Enum.with_index(contexts),
      fn {context, index} -> judge_context(score, question, context, reference, index) end,
      score.concurrency,
      score.timeout
    )
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
