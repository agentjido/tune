defmodule Tune.Execution do
  @moduledoc """
  Per-run state threaded through application program code.

  It holds the program's named parameters, the fixed model configuration for
  each role, the active role, the managed call allowance, the step limit, the
  deadline, and every completed step and failed call. Application code passes
  it through `predict/3` and `value/2` and returns the updated value.

  All versions of the state share the run's call and response records.
  Each call counts before dispatch, including calls that fail. Call
  `predict/3` and `call_program/4` from the process running the program,
  before its callback returns. Use evaluation concurrency to run independent
  cases in parallel.
  """

  alias Tune.Error
  alias Tune.ModelConfig
  alias Tune.Parameter
  alias Tune.Prediction
  alias Tune.Predictor
  alias Tune.RunLimits

  @roles [:target, :teacher, :proposal]
  @enforce_keys [:parameters, :models, :role, :journal]
  defstruct parameters: %{},
            models: %{},
            role: :target,
            max_model_calls: nil,
            journal: nil,
            max_steps: 32,
            deadline: nil,
            scope: []

  @type role :: :target | :teacher | :proposal

  @type t :: %__MODULE__{
          parameters: %{String.t() => Predictor.t() | Parameter.t()},
          models: %{optional(role()) => ModelConfig.t()},
          role: role(),
          max_model_calls: non_neg_integer() | nil,
          journal: :ets.tid(),
          max_steps: pos_integer(),
          deadline: integer() | nil,
          scope: [String.t()]
        }

  @doc "Returns the managed roles."
  @spec roles() :: [role()]
  def roles, do: @roles

  @doc false
  @spec with_run(map(), keyword(), (t() -> result)) :: result when result: var
  def with_run(parameters, opts, operation) do
    timeout = Keyword.get(opts, :timeout, 60_000)

    execution = %__MODULE__{
      parameters: parameters,
      models: Keyword.fetch!(opts, :models),
      role: Keyword.get(opts, :role, :target),
      journal: :ets.new(__MODULE__, [:private]),
      max_model_calls: Keyword.get(opts, :max_model_calls),
      max_steps: Keyword.get(opts, :max_steps, 32),
      deadline: RunLimits.expiration(timeout)
    }

    try do
      :ets.insert(execution.journal, calls: %{}, steps: [], responses: [], failures: [])
      operation.(execution)
    after
      :ets.delete(execution.journal)
    end
  end

  @doc """
  Calls the named predictor with the active role's model configuration.

  Returns the validated output map and the updated execution, or an error and
  the updated execution. The error is the original cause.
  """
  @spec predict(t(), String.t(), map()) :: {:ok, map(), t()} | {:error, term(), t()}
  def predict(%__MODULE__{} = execution, name, inputs) when is_binary(name) do
    case active(execution) do
      :ok -> predict_in_run(execution, name, inputs)
      {:error, error} -> {:error, error, execution}
    end
  end

  defp predict_in_run(execution, name, inputs) do
    with {:ok, predictor} <- fetch(execution, name, Predictor),
         {:ok, config} <- model(execution),
         :ok <- check_limits(execution),
         {:ok, prepared} <- Predictor.prepare(predictor, inputs, config),
         :ok <- check_limits(execution) do
      count_call(execution)

      case Predictor.execute(prepared, config, remaining_ms(execution)) do
        {:ok, response} -> finish_step(execution, name, prepared, response, config.model_id)
        {:error, error} -> failure(execution, name, error)
      end
    else
      {:error, error} -> failure(execution, name, error)
    end
  end

  defp finish_step(execution, name, prepared, response, model_id) do
    evidence = %{
      role: execution.role,
      model: Prediction.response_model(response, model_id),
      usage: ReqLLM.Response.usage(response)
    }

    record(execution, :responses, evidence)

    case Predictor.finish(prepared, response) do
      {:ok, step} ->
        step = %{step | name: qualified(execution, name), role: execution.role}
        record(execution, :steps, step)
        {:ok, step.outputs, execution}

      {:error, error} ->
        failure(execution, name, error)
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

    with :ok <- active(execution),
         {:ok, parameters} <- Tune.Program.parameters(program),
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
  def total_calls(%__MODULE__{} = execution),
    do: execution |> trace(:calls) |> Map.values() |> Enum.sum()

  @doc "Returns milliseconds until the deadline, or `nil` without one."
  @spec remaining_ms(t()) :: non_neg_integer() | nil
  def remaining_ms(%__MODULE__{deadline: nil}), do: nil
  def remaining_ms(%__MODULE__{deadline: deadline}), do: RunLimits.remaining(deadline)

  @doc "Returns the completed steps in call order during the active program."
  @spec steps(t()) :: [Tune.Step.t()]
  def steps(%__MODULE__{} = execution), do: execution |> trace(:steps) |> Enum.reverse()

  @doc false
  @spec prediction(t(), map() | nil) :: Prediction.t()
  def prediction(%__MODULE__{} = execution, output) do
    prediction = %Prediction{
      output: output,
      steps: steps(execution),
      failures: execution |> trace(:failures) |> Enum.reverse(),
      calls: trace(execution, :calls),
      metadata: %{responses: execution |> trace(:responses) |> Enum.reverse()}
    }

    %{prediction | usage: Prediction.token_totals(prediction)}
  end

  @doc false
  @spec last_failure(t()) :: String.t() | nil
  def last_failure(%__MODULE__{} = execution) do
    case trace(execution, :failures) do
      [%{name: name} | _] -> name
      [] -> nil
    end
  end

  defp active(execution) do
    if :ets.info(execution.journal, :owner) == self() do
      :ok
    else
      {:error,
       Error.Execution.Callback.exception(
         message: "managed calls require the active program process"
       )}
    end
  end

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
    used = total_calls(execution)

    cond do
      used >= execution.max_steps ->
        limit(:steps, "step limit of #{execution.max_steps} reached")

      remaining_ms(execution) == 0 ->
        limit(:deadline, "run deadline reached")

      is_integer(execution.max_model_calls) and used >= execution.max_model_calls ->
        limit(:model_calls, "model call limit of #{execution.max_model_calls} reached")

      true ->
        :ok
    end
  end

  defp limit(kind, message),
    do: {:error, Error.Execution.LimitReached.exception(limit: kind, message: message)}

  defp count_call(execution) do
    calls = execution |> trace(:calls) |> Map.update(execution.role, 1, &(&1 + 1))
    :ets.insert(execution.journal, {:calls, calls})
  end

  defp trace(execution, name), do: :ets.lookup_element(execution.journal, name, 2)

  defp record(execution, name, item) do
    :ets.insert(execution.journal, {name, [item | trace(execution, name)]})
  end

  defp failure(execution, name, error) do
    record(execution, :failures, %{
      name: qualified(execution, name),
      role: execution.role,
      error: error
    })

    {:error, error, execution}
  end

  defp qualified(%__MODULE__{scope: []}, name), do: name
  defp qualified(%__MODULE__{scope: scope}, name), do: Enum.join(scope ++ [name], ".")
end
