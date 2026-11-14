defmodule Tune.Predictor do
  @moduledoc """
  An immutable typed predictor: a signature and its demonstrations.

  `prepare/3` and `finish/2` are pure. `call/3` composes them with one
  `ReqLLM.generate_text/3` request. There is no retry, repair, extraction call,
  or format fallback; ReqLLM owns transport retries.
  """

  alias ReqLLM.Response
  alias Tune.Demo
  alias Tune.Error
  alias Tune.ModelConfig
  alias Tune.Prepared
  alias Tune.Signature
  alias Tune.Step

  @enforce_keys [:signature]
  defstruct signature: nil, demos: []

  @type t :: %__MODULE__{signature: Signature.t(), demos: [Demo.t()]}

  @doc """
  Builds a predictor.

  Options:

    * `:signature` - a `Tune.Signature` or signature options
    * `:demos` - demonstrations validated against the signature
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def new(opts) when is_list(opts) do
    with :ok <- check_keys(opts),
         {:ok, signature} <- signature(Keyword.get(opts, :signature)),
         {:ok, demos} <- Demo.new_list(signature, Keyword.get(opts, :demos, [])) do
      {:ok, %__MODULE__{signature: signature, demos: demos}}
    end
  end

  @doc "Returns the predictor with new validated demonstrations."
  @spec put_demos(t(), list()) :: {:ok, t()} | {:error, Exception.t()}
  def put_demos(%__MODULE__{signature: signature} = predictor, demos) do
    with {:ok, demos} <- Demo.new_list(signature, demos) do
      {:ok, %{predictor | demos: demos}}
    end
  end

  @doc "Returns the predictor with new instructions."
  @spec put_instructions(t(), String.t()) :: {:ok, t()} | {:error, Exception.t()}
  def put_instructions(%__MODULE__{signature: signature} = predictor, instructions) do
    with {:ok, signature} <- Signature.put_instructions(signature, instructions) do
      {:ok, %{predictor | signature: signature}}
    end
  end

  @doc """
  Validates inputs and renders a request with the configured adapter.

  Makes no model request and holds no credentials.
  """
  @spec prepare(t(), map(), ModelConfig.t()) :: {:ok, Prepared.t()} | {:error, Exception.t()}
  def prepare(%__MODULE__{signature: signature, demos: demos}, inputs, %ModelConfig{} = config) do
    with {:ok, inputs} <- Signature.normalize_inputs(signature, inputs),
         {:ok, %{context: context, output: output}} <-
           config.adapter.render(signature, demos, inputs, config.adapter_options) do
      {:ok,
       %Prepared{
         signature: signature,
         demos: demos,
         inputs: inputs,
         adapter: config.adapter,
         adapter_options: config.adapter_options,
         context: context,
         output: output
       }}
    end
  end

  @doc """
  Checks a response against a prepared request and returns a validated step.

  The response must have no error or refusal and a completed finish reason:
  `:stop`, or `:tool_calls` for structured output only. Structured output must
  be strictly valid with no ReqLLM repair. Makes no model request.
  """
  @spec finish(Prepared.t(), Response.t()) :: {:ok, Step.t()} | {:error, Exception.t()}
  def finish(%Prepared{} = prepared, %Response{} = response) do
    with :ok <- check_response(prepared, response),
         {:ok, reply} <- reply(prepared, response),
         {:ok, parsed} <- parse(prepared, reply, response),
         {:ok, outputs} <- validate(prepared, parsed, response) do
      {:ok,
       %Step{
         name: nil,
         signature: prepared.signature,
         inputs: prepared.inputs,
         outputs: outputs,
         response: response
       }}
    end
  end

  @doc """
  Prepares, executes one ReqLLM request, and finishes.

  Input errors return before any request. A ReqLLM error is returned unchanged.
  `remaining_ms` caps the request's `:total_timeout`.
  """
  @spec call(t(), map(), ModelConfig.t(), non_neg_integer() | nil) ::
          {:ok, Step.t()} | {:error, Exception.t() | term()}
  def call(%__MODULE__{} = predictor, inputs, %ModelConfig{} = config, remaining_ms \\ nil) do
    with {:ok, prepared} <- prepare(predictor, inputs, config),
         {:ok, response} <- execute(prepared, config, remaining_ms) do
      finish(prepared, response)
    end
  end

  @doc false
  @spec execute(Prepared.t(), ModelConfig.t(), non_neg_integer() | nil) ::
          {:ok, Response.t()} | {:error, term()}
  def execute(%Prepared{} = prepared, %ModelConfig{} = config, remaining_ms) do
    ReqLLM.generate_text(
      config.model,
      prepared.context,
      ModelConfig.request_options(config, prepared.output, remaining_ms)
    )
  end

  defp check_keys(opts) do
    case Keyword.keys(opts) -- [:signature, :demos] do
      [] ->
        :ok

      [key | _] ->
        {:error, Error.Invalid.Option.exception(option: key, message: "unknown predictor option")}
    end
  end

  defp signature(%Signature{} = signature), do: {:ok, signature}
  defp signature(opts) when is_list(opts) or is_map(opts), do: Signature.new(opts)

  defp signature(other),
    do:
      {:error,
       Error.Invalid.Definition.exception(message: "invalid signature: #{inspect(other)}")}

  defp check_response(prepared, response) do
    cond do
      response.error != nil ->
        rejected(
          :response_error,
          "the response carries an error: #{inspect(response.error)}",
          response
        )

      Response.refusals(response) != [] ->
        rejected(:refusal, "the model refused the request", response)

      response.finish_reason == :stop ->
        :ok

      response.finish_reason == :tool_calls and prepared.output.type != :text ->
        :ok

      true ->
        rejected(
          :finish_reason,
          "incomplete response: finish reason #{inspect(response.finish_reason)}",
          response
        )
    end
  end

  defp reply(%Prepared{output: %ReqLLM.Output{type: :text}}, response),
    do: {:ok, {:text, Response.text(response) || ""}}

  defp reply(%Prepared{output: output}, response) do
    result = Response.output_result(response, output, policy: :strict)

    cond do
      result.repairs != [] ->
        rejected(:repaired, "ReqLLM repaired the structured output", response)

      not result.valid? or not is_map(result.value) ->
        {:error,
         Error.Output.Invalid.exception(
           message:
             "structured output is invalid: " <> Enum.map_join(result.errors, "; ", & &1.message),
           errors: result.errors,
           value: result.value,
           response: response
         )}

      true ->
        {:ok, {:object, result.value}}
    end
  end

  defp parse(prepared, reply, response) do
    case prepared.adapter.parse(prepared.signature, reply, prepared.adapter_options) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, %Error.Output.Parse{} = error} -> {:error, %{error | response: response}}
      {:error, error} -> {:error, error}
    end
  end

  defp validate(prepared, parsed, response) do
    case Signature.validate_outputs(prepared.signature, parsed) do
      {:ok, outputs} ->
        {:ok, outputs}

      {:error, errors} ->
        {:error,
         Error.Output.Invalid.exception(
           message: Signature.format_errors("invalid outputs", errors),
           errors: errors,
           value: parsed,
           response: response
         )}
    end
  end

  defp rejected(reason, message, response),
    do:
      {:error,
       Error.Output.Rejected.exception(reason: reason, message: message, response: response)}
end
