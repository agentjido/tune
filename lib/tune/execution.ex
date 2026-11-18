defmodule Tune.Execution do
  @moduledoc """
  Immutable per-run state threaded through application program code.

  It holds the program's named parameters, the fixed model configuration for
  each role, the active role, the managed call allowance, the step limit, the
  deadline, and every completed step and failed call. Application code passes
  it through `predict/3` and `value/2` and returns the updated value.

  Every managed model call is counted before dispatch, including calls that
  fail. Work done by application code outside these functions is not managed.
  """

  alias Tune.Error
  alias Tune.ModelConfig
  alias Tune.Parameter
  alias Tune.Prediction
  alias Tune.Predictor

  @roles [:target, :teacher, :proposal]

  @enforce_keys [:parameters, :models, :role]
  defstruct parameters: %{},
            models: %{},
            role: :target,
            max_model_calls: nil,
            calls: %{},
            max_steps: 32,
            steps_taken: 0,
            deadline: nil,
            scope: [],
            steps: [],
            responses: [],
            failures: []

  @type role :: :target | :teacher | :proposal

  @type t :: %__MODULE__{
          parameters: %{String.t() => Predictor.t() | Parameter.t()},
          models: %{optional(role()) => ModelConfig.t()},
          role: role(),
          max_model_calls: non_neg_integer() | nil,
          calls: %{optional(role()) => non_neg_integer()},
          max_steps: pos_integer(),
          steps_taken: non_neg_integer(),
          deadline: integer() | nil,
          scope: [String.t()],
          steps: [Tune.Step.t()],
          responses: [map()],
          failures: [Prediction.failure()]
        }

  @doc "Returns the managed roles."
  @spec roles() :: [role()]
  def roles, do: @roles

  @doc false
  @spec new(map(), keyword()) :: t()
  def new(parameters, opts) do
    timeout = Keyword.get(opts, :timeout, 60_000)

    %__MODULE__{
      parameters: parameters,
      models: Keyword.fetch!(opts, :models),
      role: Keyword.get(opts, :role, :target),
      max_model_calls: Keyword.get(opts, :max_model_calls),
      max_steps: Keyword.get(opts, :max_steps, 32),
      deadline: if(timeout == :infinity, do: nil, else: now() + timeout)
    }
  end

  @doc """
  Calls the named predictor with the active role's model configuration.

  Returns the validated output map and the updated execution, or an error and
  the updated execution. The error is the original cause.
  """
  @spec predict(t(), String.t(), map()) :: {:ok, map(), t()} | {:error, term(), t()}
  def predict(%__MODULE__{} = execution, name, inputs) when is_binary(name) do
    with {:ok, predictor} <- fetch(execution, name, Predictor),
         {:ok, config} <- model(execution),
         :ok <- check_limits(execution),
         {:ok, prepared} <- Predictor.prepare(predictor, inputs, config) do
      execution = count_call(execution)

      case Predictor.execute(prepared, config, remaining_ms(execution)) do
        {:ok, response} -> finish_step(execution, name, prepared, response, config.model_id)
        {:error, error} -> {:error, error, record_failure(execution, name, error)}
      end
    else
      {:error, error} -> {:error, error, record_failure(execution, name, error)}
    end
  end

  defp finish_step(execution, name, prepared, response, model_id) do
    evidence = %{
      role: execution.role,
      model: Prediction.response_model(response, model_id),
      usage: ReqLLM.Response.usage(response)
    }

    execution = %{execution | responses: [evidence | execution.responses]}

    case Predictor.finish(prepared, response) do
      {:ok, step} ->
        step = %{step | name: qualified(execution, name), role: execution.role}
        {:ok, step.outputs, %{execution | steps: [step | execution.steps]}}

      {:error, error} ->
        {:error, error, record_failure(execution, name, error)}
    end
  end

  @doc "Reads a declared JSON parameter value. Makes no model call."
  @spec value(t(), String.t()) :: {:ok, term()} | {:error, Exception.t()}
  def value(%__MODULE__{} = execution, name) when is_binary(name) do
    with {:ok, %Parameter{value: value}} <- fetch(execution, name, Parameter) do
      {:ok, value}
    end
  end

  @doc """
  Runs a nested program inside this execution.

  The nested program uses its own parameters, the given role (default: the
  active role), and this execution's allowance, step limit, and deadline.
  Its steps are recorded under `scope`.
  """
  @spec call_program(t(), term(), map(), keyword()) :: {:ok, map(), t()} | {:error, term(), t()}
  def call_program(%__MODULE__{} = execution, program, inputs, opts \\ []) do
    role = Keyword.get(opts, :role, execution.role)
    scope = Keyword.get(opts, :scope)

    with {:ok, parameters} <- Tune.Program.parameters(program),
         {:ok, signature} <- Tune.Program.signature(program),
         {:ok, inputs} <- Tune.Signature.normalize_inputs(signature, inputs) do
      nested = %{
        execution
        | parameters: parameters,
          role: role,
          scope: if(scope, do: execution.scope ++ [scope], else: execution.scope)
      }

      restore =
        &%{&1 | parameters: execution.parameters, role: execution.role, scope: execution.scope}

      case Tune.Program.invoke(program, inputs, nested) do
        {:ok, output, nested} -> {:ok, output, restore.(nested)}
        {:error, error, nested} -> {:error, error, restore.(nested)}
      end
    else
      {:error, error} -> {:error, error, execution}
    end
  end

  @doc "Returns `true` when a model configuration exists for the role."
  @spec has_role?(t(), role()) :: boolean()
  def has_role?(%__MODULE__{models: models}, role), do: Map.has_key?(models, role)

  @doc "Returns the remaining managed call allowance, or `nil` when unlimited."
  @spec remaining_calls(t()) :: non_neg_integer() | nil
  def remaining_calls(%__MODULE__{max_model_calls: nil}), do: nil

  def remaining_calls(%__MODULE__{max_model_calls: max} = execution),
    do: max(max - total_calls(execution), 0)

  @doc "Returns attempted managed calls across roles."
  @spec total_calls(t()) :: non_neg_integer()
  def total_calls(%__MODULE__{calls: calls}), do: calls |> Map.values() |> Enum.sum()

  @doc "Returns milliseconds until the deadline, or `nil` without one."
  @spec remaining_ms(t()) :: non_neg_integer() | nil
  def remaining_ms(%__MODULE__{deadline: nil}), do: nil
  def remaining_ms(%__MODULE__{deadline: deadline}), do: max(deadline - now(), 0)

  @doc false
  @spec prediction(t(), map() | nil) :: Prediction.t()
  def prediction(%__MODULE__{} = execution, output) do
    %Prediction{
      output: output,
      steps: Enum.reverse(execution.steps),
      failures: Enum.reverse(execution.failures),
      calls: execution.calls,
      metadata: %{responses: Enum.reverse(execution.responses)}
    }
  end

  @doc false
  @spec last_failure(t()) :: String.t() | nil
  def last_failure(%__MODULE__{failures: [%{name: name} | _]}), do: name
  def last_failure(%__MODULE__{}), do: nil

  defp fetch(execution, name, kind) do
    case Map.fetch(execution.parameters, name) do
      {:ok, %^kind{} = value} ->
        {:ok, value}

      {:ok, other} ->
        {:error,
         Error.Invalid.Definition.exception(
           message:
             "parameter #{inspect(name)} is a #{inspect(other.__struct__)}, not a #{inspect(kind)}"
         )}

      :error ->
        {:error,
         Error.Invalid.Definition.exception(message: "unknown parameter #{inspect(name)}")}
    end
  end

  defp model(execution) do
    case Map.fetch(execution.models, execution.role) do
      {:ok, config} ->
        {:ok, config}

      :error ->
        {:error,
         Error.Invalid.Option.exception(
           option: execution.role,
           message: "no model configuration for the #{execution.role} role"
         )}
    end
  end

  defp check_limits(execution) do
    cond do
      execution.steps_taken >= execution.max_steps ->
        limit(:steps, "step limit of #{execution.max_steps} reached")

      execution.deadline != nil and remaining_ms(execution) <= 0 ->
        limit(:deadline, "run deadline reached")

      remaining_calls(execution) == 0 ->
        limit(:model_calls, "model call limit of #{execution.max_model_calls} reached")

      true ->
        :ok
    end
  end

  defp limit(kind, message),
    do: {:error, Error.Execution.LimitReached.exception(limit: kind, message: message)}

  defp count_call(execution) do
    %{
      execution
      | calls: Map.update(execution.calls, execution.role, 1, &(&1 + 1)),
        steps_taken: execution.steps_taken + 1
    }
  end

  defp record_failure(execution, name, error) do
    failure = %{name: qualified(execution, name), role: execution.role, error: error}
    %{execution | failures: [failure | execution.failures]}
  end

  defp qualified(%__MODULE__{scope: []}, name), do: name
  defp qualified(%__MODULE__{scope: scope}, name), do: Enum.join(scope ++ [name], ".")

  defp now, do: System.monotonic_time(:millisecond)
end
