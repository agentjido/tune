defmodule Tune.Score.Judge do
  @moduledoc false

  alias Tune.Input

  @enforce_keys [:model, :model_id, :request_options]
  defstruct [:model, :model_id, :request_options]

  @type t :: %__MODULE__{model: term(), model_id: String.t(), request_options: keyword()}

  @options Zoi.keyword(
             [
               model: Zoi.any() |> Zoi.required(),
               request_options: Input.keyword_values() |> Zoi.default([]),
               timeout: Zoi.integer() |> Zoi.positive() |> Zoi.default(30_000),
               concurrency: Zoi.integer() |> Zoi.positive() |> Zoi.default(3)
             ],
             unrecognized_keys: :error
           )

  @spec configure(keyword()) :: {:ok, map()} | {:error, Exception.t()}
  def configure(opts) do
    with {:ok, opts} <- Input.options(@options, opts, :judge, :first),
         {:ok, model} <- ReqLLM.model(opts[:model]) do
      judge = %__MODULE__{
        model: model,
        model_id: LLMDB.Model.spec(model),
        request_options: opts[:request_options]
      }

      {:ok, %{judge: judge, timeout: opts[:timeout], concurrency: opts[:concurrency]}}
    end
  end

  @spec object(t(), String.t(), Zoi.schema(), keyword()) ::
          {:ok, map(), map()} | {:error, term(), map()}
  def object(%__MODULE__{} = judge, prompt, schema, opts \\ []) do
    started_at = System.monotonic_time(:millisecond)
    timeout = Keyword.get(opts, :timeout)

    request_options =
      judge.request_options
      |> Keyword.put_new(:output_validation, :strict)
      |> Keyword.put_new(:json_repair, false)
      |> put_timeout(timeout)

    call = %{type: :object, model: judge.model_id}

    case ReqLLM.generate_object(judge.model, prompt, schema, request_options) do
      {:ok, response} ->
        evidence =
          Map.merge(call, %{
            usage: ReqLLM.Response.usage(response),
            finish_reason: ReqLLM.Response.finish_reason(response),
            provider_meta: response.provider_meta,
            latency_ms: System.monotonic_time(:millisecond) - started_at,
            response: response
          })

        case ReqLLM.Response.object(response) do
          object when is_map(object) -> {:ok, object, evidence}
          _ -> {:error, :missing_judge_object, evidence}
        end

      {:error, error} ->
        {:error, error,
         Map.put(call, :latency_ms, System.monotonic_time(:millisecond) - started_at)}
    end
  end

  @doc false
  @spec collect(Enumerable.t(), function(), pos_integer(), pos_integer()) ::
          {:ok, list(), list()} | {:error, term(), list()}
  def collect(items, callback, concurrency, timeout) do
    items
    |> Task.async_stream(callback,
      ordered: true,
      max_concurrency: concurrency,
      timeout: timeout,
      on_timeout: :kill_task
    )
    |> Enum.reduce({[], [], nil}, fn
      {:ok, {:ok, value, call}}, {values, calls, error} ->
        {[value | values], [call | calls], error}

      {:ok, {:error, error, call}}, {values, calls, first_error} ->
        {values, [Map.put(call, :error, error) | calls], first_error || error}

      {:exit, reason}, {values, calls, first_error} ->
        error = {:judge_worker_stopped, reason}

        {values, [%{type: :object, error: error, calls_upper_bound?: true} | calls],
         first_error || error}
    end)
    |> case do
      {values, calls, nil} -> {:ok, Enum.reverse(values), Enum.reverse(calls)}
      {_values, calls, error} -> {:error, error, Enum.reverse(calls)}
    end
  end

  @doc false
  @spec evidence(list()) :: map()
  def evidence(calls), do: %{judge_calls: calls, calls: %{judge: length(calls)}}

  defp put_timeout(opts, nil), do: opts
  defp put_timeout(opts, timeout), do: Keyword.put(opts, :total_timeout, timeout)
end
