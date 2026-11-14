defmodule Tune.Score.Judge do
  @moduledoc false

  @enforce_keys [:model, :model_id, :request_options]
  defstruct [:model, :model_id, :request_options]

  @type t :: %__MODULE__{model: term(), model_id: String.t(), request_options: keyword()}

  @spec new(keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def new(opts) when is_list(opts) do
    with :ok <- keys(opts),
         {:ok, model} <- model(opts),
         {:ok, request_options} <- request_options(opts) do
      {:ok,
       %__MODULE__{
         model: model,
         model_id: LLMDB.Model.spec(model),
         request_options: request_options
       }}
    end
  end

  @spec object(t(), String.t(), Zoi.schema(), keyword()) ::
          {:ok, map(), map()} | {:error, term()}
  def object(%__MODULE__{} = judge, prompt, schema, opts \\ []) do
    started_at = System.monotonic_time(:millisecond)
    timeout = Keyword.get(opts, :timeout)

    request_options =
      judge.request_options
      |> Keyword.put_new(:output_validation, :strict)
      |> Keyword.put_new(:json_repair, false)
      |> put_timeout(timeout)

    with {:ok, response} <- ReqLLM.generate_object(judge.model, prompt, schema, request_options),
         object when is_map(object) <- ReqLLM.Response.object(response) do
      {:ok, object,
       %{
         type: :object,
         model: judge.model_id,
         usage: ReqLLM.Response.usage(response),
         finish_reason: ReqLLM.Response.finish_reason(response),
         provider_meta: response.provider_meta,
         latency_ms: System.monotonic_time(:millisecond) - started_at,
         response: response
       }}
    else
      nil -> invalid("judge returned no object")
      {:error, error} -> {:error, error}
    end
  end

  defp model(opts) do
    case Keyword.fetch(opts, :model) do
      {:ok, input} -> ReqLLM.model(input)
      :error -> invalid("judge model is required")
    end
  end

  defp request_options(opts) do
    case Keyword.get(opts, :request_options, []) do
      value when is_list(value) -> {:ok, value}
      _ -> invalid("judge request_options must be a keyword list")
    end
  end

  defp keys(opts) do
    case Keyword.keys(opts) -- [:model, :request_options] do
      [] -> :ok
      [key | _] -> invalid("unknown judge option #{inspect(key)}")
    end
  end

  defp put_timeout(opts, nil), do: opts
  defp put_timeout(opts, timeout), do: Keyword.put(opts, :total_timeout, timeout)

  defp invalid(message),
    do: {:error, Tune.Error.Invalid.Option.exception(option: :judge, message: message)}
end
