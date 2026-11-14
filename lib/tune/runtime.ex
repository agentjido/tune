defmodule Tune.Runtime do
  @moduledoc false

  alias Tune.Error
  alias Tune.Execution
  alias Tune.ModelConfig
  alias Tune.Prediction
  alias Tune.Program
  alias Tune.Signature

  @run_options [:model, :teacher, :proposal, :role, :max_model_calls, :max_steps, :timeout]

  @spec run(Program.t(), map(), keyword()) ::
          {:ok, Prediction.t()} | {:error, Exception.t()}
  def run(program, inputs, opts) when is_list(opts) do
    with {:ok, run_opts} <- normalize_options(opts),
         {:ok, execution} <- new_execution(program, run_opts) do
      run_with(program, inputs, execution)
    end
  end

  @spec run_with(Program.t(), map(), Execution.t()) ::
          {:ok, Prediction.t()} | {:error, Exception.t()}
  def run_with(program, inputs, %Execution{} = execution) do
    with {:ok, signature} <- Program.signature(program),
         {:ok, inputs} <- Signature.normalize_inputs(signature, inputs) do
      case Program.invoke(program, inputs, execution) do
        {:ok, output, execution} ->
          validate_output(signature, output, execution)

        {:error, cause, execution} ->
          {:error,
           Error.Execution.Failed.exception(
             cause: cause,
             result: Execution.prediction(execution, nil),
             step: Execution.last_failure(execution)
           )}
      end
    end
  end

  @spec new_execution(Program.t(), keyword()) ::
          {:ok, Execution.t()} | {:error, Exception.t()}
  def new_execution(program, run_opts) do
    with {:ok, parameters} <- Program.parameters(program) do
      {:ok, Execution.new(parameters, run_opts)}
    end
  end

  @spec normalize_options(keyword()) :: {:ok, keyword()} | {:error, Exception.t()}
  def normalize_options(opts) do
    with :ok <- check_keys(opts),
         {:ok, models} <- models(opts),
         {:ok, role} <- role(opts, models),
         {:ok, max_calls} <- optional_count(opts, :max_model_calls, 0),
         {:ok, max_steps} <- optional_count(opts, :max_steps, 1),
         {:ok, timeout} <- timeout(opts) do
      {:ok,
       [
         models: models,
         role: role,
         max_model_calls: max_calls,
         max_steps: max_steps || 32,
         timeout: timeout
       ]}
    end
  end

  defp validate_output(signature, output, execution) do
    case Signature.validate_outputs(signature, output) do
      {:ok, output} ->
        {:ok, Execution.prediction(execution, output)}

      {:error, errors} ->
        cause =
          Error.Output.Invalid.exception(
            message: Signature.format_errors("invalid program output", errors),
            errors: errors,
            value: output
          )

        {:error,
         Error.Execution.Failed.exception(
           cause: cause,
           result: Execution.prediction(execution, nil),
           step: nil
         )}
    end
  end

  defp check_keys(opts) do
    case Keyword.keys(opts) -- @run_options do
      [] -> :ok
      [key | _] -> option_error(key, "unknown run option")
    end
  end

  defp models(opts) do
    Enum.reduce_while(Execution.roles(), {:ok, %{}}, fn role, {:ok, acc} ->
      key = if role == :target, do: :model, else: role

      case Keyword.fetch(opts, key) do
        {:ok, config} ->
          case ModelConfig.new(config) do
            {:ok, config} -> {:cont, {:ok, Map.put(acc, role, config)}}
            error -> {:halt, error}
          end

        :error ->
          {:cont, {:ok, acc}}
      end
    end)
    |> then(fn
      {:ok, models} when is_map_key(models, :target) -> {:ok, models}
      {:ok, _} -> option_error(:model, "is required")
      error -> error
    end)
  end

  defp role(opts, models) do
    role = Keyword.get(opts, :role, :target)

    cond do
      role not in Execution.roles() ->
        option_error(:role, "must be one of #{inspect(Execution.roles())}")

      not Map.has_key?(models, role) ->
        option_error(:role, "no model configuration for #{inspect(role)}")

      true ->
        {:ok, role}
    end
  end

  defp optional_count(opts, key, min) do
    case Keyword.get(opts, key) do
      nil -> {:ok, nil}
      value when is_integer(value) and value >= min -> {:ok, value}
      _ -> option_error(key, "must be an integer >= #{min}")
    end
  end

  defp timeout(opts) do
    case Keyword.get(opts, :timeout, 60_000) do
      :infinity -> {:ok, :infinity}
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> option_error(:timeout, "must be a nonnegative integer or :infinity")
    end
  end

  defp option_error(option, message),
    do: {:error, Error.Invalid.Option.exception(option: option, message: message)}
end
