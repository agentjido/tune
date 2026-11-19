defmodule Tune.Runtime do
  @moduledoc """
  Runs a typed predictor or composed program on one input.

  Use `run/3` to execute a program in an application, including a program
  loaded from an artifact.
  """

  alias Tune.Error
  alias Tune.Execution
  alias Tune.Input
  alias Tune.ModelConfig
  alias Tune.Prediction
  alias Tune.Program
  alias Tune.Signature

  @run_options Zoi.keyword(
                 [
                   model: Zoi.any() |> Zoi.required(),
                   teacher: Zoi.any() |> Zoi.optional(),
                   proposal: Zoi.any() |> Zoi.optional(),
                   role: Zoi.enum(Execution.roles()) |> Zoi.default(:target),
                   max_model_calls: Zoi.integer() |> Zoi.gte(0) |> Zoi.nullable(),
                   max_steps: Zoi.integer() |> Zoi.positive() |> Zoi.nullable(),
                   timeout:
                     Zoi.union([Zoi.integer() |> Zoi.gte(0), Zoi.literal(:infinity)])
                     |> Zoi.default(60_000)
                 ],
                 unrecognized_keys: :error
               )

  @doc """
  Runs a program with a required `:model` configuration and returns a
  `Tune.Prediction` with its output, steps, and call counts.

  Pass `:max_model_calls`, `:max_steps`, or `:timeout` to bound execution.
  Timeout is in milliseconds and defaults to 60,000. Use `:infinity` for
  no timeout. If a program fails after it starts, the error retains the
  partial prediction.
  """
  @spec run(Program.t(), map(), keyword()) ::
          {:ok, Prediction.t()} | {:error, Exception.t()}
  def run(program, inputs, opts) when is_list(opts) do
    with {:ok, run_opts} <- normalize_options(opts),
         {:ok, parameters} <- Program.parameters(program),
         {:ok, signature} <- Program.signature(program) do
      execute(program, signature, parameters, inputs, run_opts)
    end
  end

  @doc false
  @spec execute(Program.t(), Signature.t(), Program.parameters(), map(), keyword()) ::
          {:ok, Prediction.t()} | {:error, Exception.t()}
  def execute(program, signature, parameters, inputs, options) do
    with {:ok, inputs} <- Signature.normalize_inputs(signature, inputs) do
      Execution.with_run(parameters, options, fn execution ->
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
      end)
    end
  end

  @doc false
  @spec normalize_options(keyword()) :: {:ok, keyword()} | {:error, Exception.t()}
  def normalize_options(opts) do
    with {:ok, opts} <- Input.options(@run_options, opts, :run, :first),
         {:ok, models} <- models(opts),
         :ok <- check_role(opts[:role], models) do
      {:ok,
       [
         models: models,
         role: opts[:role],
         max_model_calls: opts[:max_model_calls],
         max_steps: opts[:max_steps] || 32,
         timeout: opts[:timeout]
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
  end

  defp check_role(role, models) when is_map_key(models, role), do: :ok

  defp check_role(role, _models),
    do: option_error(:role, "no model configuration for #{inspect(role)}")

  defp option_error(option, message),
    do: {:error, Error.Invalid.Option.exception(option: option, message: message)}
end
