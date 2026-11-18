defmodule Tune.Scores.Faithfulness do
  @moduledoc "A structured ReqLLM judge for grounded-response faithfulness."
  @behaviour Tune.Score

  alias Tune.Case
  alias Tune.Score.Judge

  @enforce_keys [:judge]
  defstruct [:judge, timeout: 30_000, concurrency: 3]

  @statement_schema Zoi.object(%{
                      "statements" =>
                        Zoi.array(
                          Zoi.object(%{
                            "text" => Zoi.string()
                          })
                        )
                    })

  @support_schema Zoi.object(%{
                    "supported" => Zoi.boolean(),
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
  def score(%__MODULE__{} = score, %Case{} = tune_case, output) do
    with {:ok, response} <- response(output),
         {:ok, contexts} <- contexts(tune_case.input),
         :ok <- require_calls(tune_case, 1),
         {:ok, statements, extraction_call} <- statements(score, response) do
      score_statements(score, tune_case, statements, contexts, extraction_call)
    else
      {:error, error, call} -> {:error, error, Judge.evidence([Map.put(call, :error, error)])}
      {:error, error} -> {:error, error}
    end
  end

  defp score_statements(score, tune_case, statements, contexts, extraction_call) do
    with :ok <- require_calls(tune_case, 1 + length(statements)),
         {:ok, checks, check_calls} <- checks(score, statements, contexts) do
      supported = Enum.count(checks, & &1.supported)
      value = if checks == [], do: 0.0, else: supported / length(checks)

      Map.merge(Judge.evidence([extraction_call | check_calls]), %{
        score: value,
        feedback: "#{supported}/#{length(checks)} statements supported",
        details: %{statements: checks, supported_count: supported}
      })
    else
      {:error, error, calls} -> {:error, error, Judge.evidence([extraction_call | calls])}
      {:error, error} -> {:error, error, Judge.evidence([extraction_call])}
    end
  end

  @impl true
  def model_calls?(%__MODULE__{}), do: true

  defp statements(score, response) do
    prompt = """
    Extract the individual factual claims from this response.
    Return concise standalone claims with no duplicates.

    Response:
    #{response}
    """

    with {:ok, object, call} <-
           Judge.object(score.judge, prompt, @statement_schema, timeout: score.timeout) do
      statements =
        object
        |> get(:statements, [])
        |> Enum.map(&get(&1, :text, ""))
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      {:ok, if(statements == [], do: [response], else: statements), call}
    end
  end

  defp checks(score, statements, contexts) do
    rendered_contexts = Enum.map_join(contexts, "\n\n", &to_string/1)

    Judge.collect(
      statements,
      fn statement -> check(score, statement, rendered_contexts) end,
      score.concurrency,
      score.timeout
    )
  end

  defp check(score, statement, contexts) do
    prompt = """
    Decide whether the statement is supported by or can be inferred from the contexts.
    Use only the supplied contexts.

    Contexts:
    #{contexts}

    Statement:
    #{statement}
    """

    with {:ok, object, call} <-
           Judge.object(score.judge, prompt, @support_schema, timeout: score.timeout) do
      {:ok,
       %{
         text: statement,
         supported: get(object, :supported, false),
         reasoning: get(object, :reasoning, "")
       }, call}
    end
  end

  defp response(output) when is_binary(output) and output != "", do: {:ok, output}

  defp response(output) when is_map(output) do
    case get(output, :response) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> invalid("output must contain a nonempty response")
    end
  end

  defp response(_output), do: invalid("output must be text or contain a response")

  defp contexts(input) when is_map(input) do
    case get(input, :retrieved_contexts) do
      values when is_list(values) and values != [] -> {:ok, values}
      _ -> invalid("case input must contain retrieved_contexts")
    end
  end

  defp contexts(_input), do: invalid("case input must be a map")

  defp require_calls(tune_case, required) do
    case allowance(tune_case) do
      nil -> :ok
      value when value >= required -> :ok
      _value -> {:error, limit_error()}
    end
  end

  defp allowance(%Case{metadata: metadata}), do: Map.get(metadata, :model_call_allowance)

  defp limit_error do
    Tune.Error.Execution.LimitReached.exception(
      limit: :model_calls,
      message: "faithfulness judge call limit reached"
    )
  end

  defp get(map, key, default \\ nil), do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp invalid(message),
    do: {:error, Tune.Error.Invalid.Input.exception(message: message, errors: [])}
end
