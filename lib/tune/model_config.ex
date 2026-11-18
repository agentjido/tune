defmodule Tune.ModelConfig do
  @moduledoc """
  One explicit, fixed model configuration: a ReqLLM model, a prompt adapter,
  adapter options, and ReqLLM request options.

      {:ok, config} =
        Tune.ModelConfig.new(
          model: "openai:gpt-4o-mini",
          adapter: Tune.Adapter.Chat,
          request_options: [temperature: 0.0]
        )

  The adapter is always explicit. Request options pass through to ReqLLM,
  except options that would replace the prepared output contract, change the
  prompt, add tools, stream, or repair output. Managed requests always send
  `json_repair: false`.

  Request options can hold credentials. They are never copied into prepared
  requests, steps, results, or artifacts.
  """

  alias Tune.Error
  alias Tune.Input

  @forbidden_request_options [
    :output,
    :output_repair,
    :output_validation,
    :system_prompt,
    :tools,
    :tool_choice,
    :stream,
    :object_schema
  ]

  @keyword_values Input.keyword_values()
  @options Zoi.keyword(
             [
               model: Zoi.any() |> Zoi.required(),
               adapter: Zoi.atom() |> Zoi.required(),
               adapter_options: @keyword_values |> Zoi.default([]),
               request_options: @keyword_values |> Zoi.default([])
             ],
             unrecognized_keys: :error
           )
  @timeout Zoi.union([Zoi.integer() |> Zoi.positive(), Zoi.literal(:infinity), Zoi.null()])

  @enforce_keys [:model, :model_id, :adapter, :adapter_options, :request_options]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          model: term(),
          model_id: String.t(),
          adapter: module(),
          adapter_options: keyword(),
          request_options: keyword()
        }

  @doc """
  Builds a model configuration.

  Options:

    * `:model` - required ReqLLM model input, resolved through `ReqLLM.model/1`
    * `:adapter` - required module implementing `Tune.Adapter`
    * `:adapter_options` - options validated by the adapter
    * `:request_options` - ReqLLM generation options
  """
  @spec new(t() | keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%__MODULE__{} = config), do: {:ok, config}

  def new(opts) when is_list(opts) do
    with {:ok, opts} <- Input.options(@options, opts, :model, :first),
         {:ok, model, model_id} <- model(opts),
         {:ok, adapter} <- adapter(opts),
         {:ok, adapter_options} <- adapter_options(adapter, opts),
         {:ok, request_options} <- request_options(opts) do
      {:ok,
       %__MODULE__{
         model: model,
         model_id: model_id,
         adapter: adapter,
         adapter_options: adapter_options,
         request_options: request_options
       }}
    end
  end

  def new(other),
    do: definition_error("model configuration must be a keyword list, got: #{inspect(other)}")

  @doc """
  Returns ReqLLM options for one managed request.

  `output` is the prepared output descriptor. `remaining_ms`, when given, caps
  `:total_timeout` so the request cannot outlive the run deadline.
  """
  @spec request_options(t(), ReqLLM.Output.t(), non_neg_integer() | nil) :: keyword()
  def request_options(
        %__MODULE__{request_options: opts},
        %ReqLLM.Output{} = output,
        remaining_ms \\ nil
      ) do
    opts
    |> Keyword.put(:output, output)
    |> Keyword.put(:json_repair, false)
    |> put_validation(output)
    |> put_timeout(remaining_ms)
  end

  @doc "Returns non-secret identifiers for provenance and reports."
  @spec describe(t()) :: map()
  def describe(%__MODULE__{} = config) do
    %{
      "model" => config.model_id,
      "adapter" => inspect(config.adapter),
      "adapter_options" =>
        Map.new(config.adapter_options, fn {k, v} -> {Atom.to_string(k), describe_value(v)} end)
    }
  end

  defp describe_value(value) when is_atom(value), do: Atom.to_string(value)
  defp describe_value(value), do: value

  defp put_validation(opts, %ReqLLM.Output{type: :text}), do: opts
  defp put_validation(opts, %ReqLLM.Output{}), do: Keyword.put(opts, :output_validation, :strict)

  defp put_timeout(opts, nil), do: opts

  defp put_timeout(opts, remaining_ms) do
    case Keyword.get(opts, :total_timeout) do
      configured when is_integer(configured) and configured <= remaining_ms -> opts
      _ -> Keyword.put(opts, :total_timeout, max(remaining_ms, 1))
    end
  end

  defp model(opts) do
    model = Keyword.fetch!(opts, :model)

    case ReqLLM.model(model) do
      {:ok, %LLMDB.Model{provider: provider, id: id}} ->
        {:ok, model, "#{provider}:#{id}"}

      {:error, cause} ->
        {:error, Error.Invalid.Definition.exception(message: "invalid model", details: cause)}
    end
  end

  defp adapter(opts) do
    adapter = Keyword.fetch!(opts, :adapter)

    if adapter?(adapter),
      do: {:ok, adapter},
      else: option_error(:adapter, "#{inspect(adapter)} is not a Tune.Adapter")
  end

  defp adapter?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :render, 4) and
      function_exported?(module, :parse, 3) and function_exported?(module, :normalize_options, 1)
  end

  defp adapter_options(adapter, opts), do: adapter.normalize_options(opts[:adapter_options])

  defp request_options(opts) do
    options = opts[:request_options]

    cond do
      key = Enum.find(Keyword.keys(options), &(&1 in @forbidden_request_options)) ->
        option_error(key, "is controlled by the prompt adapter and cannot be set")

      Keyword.get(options, :json_repair, false) != false ->
        option_error(:json_repair, "managed requests never repair output")

      not match?({:ok, _}, Zoi.parse(@timeout, options[:total_timeout])) ->
        option_error(:total_timeout, "must be a positive integer or :infinity")

      true ->
        {:ok, Keyword.delete(options, :json_repair)}
    end
  end

  defp option_error(option, message),
    do: {:error, Error.Invalid.Option.exception(option: option, message: message)}

  defp definition_error(message),
    do: {:error, Error.Invalid.Definition.exception(message: message)}
end
