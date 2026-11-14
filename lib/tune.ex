defmodule Tune do
  @moduledoc """
  Typed and optimizable language-model programs built on ReqLLM.

  A program is either a `Tune.Predictor`, which is a one-step program
  with the parameter name `"root"`, or an application struct whose module
  implements this behaviour:

    * `signature/1` returns the program's input/output `Signature`
    * `parameters/1` returns a map of unique string names to `Predictor` or
      `Parameter` values
    * `put_parameters/2` returns an updated struct of the same module
    * `call/3` receives the program, normalized inputs, and an `Execution`,
      and returns `{:ok, output, execution}` or `{:error, error, execution}`

  Composition is ordinary Elixir code:

      def call(_program, inputs, execution) do
        with {:ok, facts, execution} <- Execution.predict(execution, "extract", inputs),
             {:ok, answer, execution} <-
               Execution.predict(execution, "answer", Map.put(facts, "question", inputs["question"])) do
          {:ok, answer, execution}
        end
      end
  """

  alias Tune.Error
  alias Tune.Execution
  alias Tune.ModelConfig
  alias Tune.Parameter
  alias Tune.Predictor
  alias Tune.Result
  alias Tune.Signature

  @root "root"

  @type t :: Predictor.t() | struct()
  @type parameters :: %{String.t() => Predictor.t() | Parameter.t()}

  @callback signature(program :: struct()) :: Signature.t()
  @callback parameters(program :: struct()) :: parameters()
  @callback put_parameters(program :: struct(), parameters()) :: struct()
  @callback call(program :: struct(), inputs :: map(), Execution.t()) ::
              {:ok, map(), Execution.t()} | {:error, term(), Execution.t()}

  @run_options [:model, :teacher, :proposal, :role, :max_model_calls, :max_steps, :timeout]

  @doc """
  Runs a program on one input map.

  Options:

    * `:model` - required target `ModelConfig` or its options
    * `:teacher`, `:proposal` - optional configurations for those roles
    * `:role` - active role, default `:target`
    * `:max_model_calls` - optional managed call limit for this run
    * `:max_steps` - managed call step limit, default 32
    * `:timeout` - cooperative run deadline in milliseconds or `:infinity`, default 60 000

  Invalid options and inputs return before any model request. A failure after
  the run starts returns `Tune.Error.Execution.Failed` with the
  original cause and the partial result.
  """
  @spec run(t(), map(), keyword()) :: {:ok, Result.t()} | {:error, Exception.t()}
  def run(program, inputs, opts) when is_list(opts) do
    with {:ok, run_opts} <- normalize_run_options(opts),
         {:ok, execution} <- new_execution(program, run_opts) do
      run_with(program, inputs, execution)
    end
  end

  @doc """
  Evaluates a program on a dataset.

  Takes the same model and limit options as `run/3`, where `:max_model_calls`
  is the total allowance for the evaluation, plus:

    * `:metric` - required 2-arity metric function
    * `:failure_score` - optional explicit score for failed rows
    * `:concurrency` - concurrent rows, default 1
    * `:row_timeout` - hard per-row timeout in milliseconds, default 120 000
    * `:max_row_calls` - per-row allowance, used to reserve calls for
      concurrent rows; defaults to 1 per concurrent row when a total limit is set

  Rows are `Tune.Example` values or maps with `:inputs`, `:labels`,
  and `:id`. Returns `{:ok, evaluation}` or a setup error. There is no
  optimization or dataset splitting.
  """
  @spec evaluate(t(), list(), keyword()) ::
          {:ok, Tune.Evaluation.t()} | {:error, Exception.t()}
  def evaluate(program, rows, opts) when is_list(opts) do
    {eval_opts, run_opts} = Tune.Evaluation.split_options(opts)

    with {:ok, eval_opts} <- Tune.Evaluation.normalize_options(eval_opts),
         {:ok, run_opts} <- normalize_run_options(run_opts),
         {:ok, signature} <- signature(program),
         {:ok, _parameters} <- parameters(program),
         {:ok, examples} <- Tune.Example.normalize_all(signature, rows) do
      {:ok, Tune.Evaluation.run(program, examples, run_opts, eval_opts)}
    end
  end

  @doc """
  Optimizes a program and returns a new program with a report.

  Options:

    * `:optimizer` - required optimizer module or `{module, options}`
    * `:trainset` - training rows; required by algorithms that learn from data
    * `:valset` - validation rows; required by candidate searches, never split automatically
    * `:metric` - 2-arity metric; required unless the algorithm declares otherwise
    * `:failure_score` - optional explicit score for failed rows
    * `:model` - required target configuration, fixed for the run
    * `:teacher`, `:proposal` - explicit configurations when the algorithm uses them
    * `:max_model_calls` - required when the algorithm calls models
    * `:seed` - local random seed, default 0
    * `:max_steps`, `:timeout` - per-run limits, as in `run/3`
    * `:row_timeout` - hard per-row timeout for evaluations

  `:testset` is rejected; final test evaluation is a separate `evaluate/3` call.
  Exact duplicate training rows are removed once and counted in the report.
  Validation rows with the same inputs as a training row are a setup error.

  Returns `{:ok, program, report}`, or `{:error, %Tune.Error.Optimization.Failed{}}`
  with the report and original cause. A run stopped by the call limit returns
  its best complete eligible candidate with `complete?: false`.
  """
  @spec optimize(t(), keyword()) ::
          {:ok, t(), Tune.Optimizer.Report.t()} | {:error, Exception.t()}
  def optimize(program, opts) when is_list(opts), do: Tune.Optimize.run(program, opts)

  @doc false
  @spec run_with(t(), map(), Execution.t()) :: {:ok, Result.t()} | {:error, Exception.t()}
  def run_with(program, inputs, %Execution{} = execution) do
    with {:ok, signature} <- signature(program),
         {:ok, inputs} <- Signature.normalize_inputs(signature, inputs) do
      case invoke(program, inputs, execution) do
        {:ok, output, execution} ->
          case Signature.validate_outputs(signature, output) do
            {:ok, output} ->
              {:ok, Execution.result(execution, output)}

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
                 result: Execution.result(execution, nil),
                 step: nil
               )}
          end

        {:error, cause, execution} ->
          {:error,
           Error.Execution.Failed.exception(
             cause: cause,
             result: Execution.result(execution, nil),
             step: Execution.last_failure(execution)
           )}
      end
    end
  end

  @doc false
  @spec new_execution(t(), keyword()) :: {:ok, Execution.t()} | {:error, Exception.t()}
  def new_execution(program, run_opts) do
    with {:ok, parameters} <- parameters(program) do
      {:ok, Execution.new(parameters, run_opts)}
    end
  end

  @doc false
  @spec normalize_run_options(keyword()) :: {:ok, keyword()} | {:error, Exception.t()}
  def normalize_run_options(opts) do
    with :ok <- check_run_keys(opts),
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

  @doc "Returns the program's signature."
  @spec signature(t()) :: {:ok, Signature.t()} | {:error, Exception.t()}
  def signature(%Predictor{signature: signature}), do: {:ok, signature}

  def signature(%module{} = program) do
    with :ok <- check_program_module(module) do
      case module.signature(program) do
        %Signature{} = signature -> {:ok, signature}
        other -> callback_error("#{inspect(module)}.signature/1 must return a Signature", other)
      end
    end
  end

  def signature(other), do: callback_error("not a program", other)

  @doc "Returns the program's declared parameters."
  @spec parameters(t()) :: {:ok, parameters()} | {:error, Exception.t()}
  def parameters(%Predictor{} = predictor), do: {:ok, %{@root => predictor}}

  def parameters(%module{} = program) do
    with :ok <- check_program_module(module) do
      program |> module.parameters() |> check_parameters(module)
    end
  end

  def parameters(other), do: callback_error("not a program", other)

  @doc """
  Replaces named parameters and returns the updated program.

  Every name must already be declared, each value must have the same kind, and
  a replacement predictor must keep the declared signature fields. The original
  program is unchanged.
  """
  @spec replace_parameters(t(), parameters()) :: {:ok, t()} | {:error, Exception.t()}
  def replace_parameters(program, updates) when is_map(updates) do
    with {:ok, current} <- parameters(program),
         :ok <- check_updates(current, updates) do
      merged = Map.merge(current, updates)
      put_parameters(program, merged)
    end
  end

  defp put_parameters(%Predictor{}, %{@root => %Predictor{} = predictor}), do: {:ok, predictor}

  defp put_parameters(%module{} = program, parameters) do
    case module.put_parameters(program, parameters) do
      %^module{} = updated ->
        case parameters(updated) do
          {:ok, ^parameters} ->
            {:ok, updated}

          {:ok, _} ->
            callback_error(
              "#{inspect(module)}.put_parameters/2 did not apply every value",
              updated
            )

          error ->
            error
        end

      other ->
        callback_error(
          "#{inspect(module)}.put_parameters/2 must return a #{inspect(module)}",
          other
        )
    end
  end

  @doc false
  @spec invoke(t(), map(), Execution.t()) ::
          {:ok, map(), Execution.t()} | {:error, term(), Execution.t()}
  def invoke(%Predictor{}, inputs, execution), do: Execution.predict(execution, @root, inputs)

  def invoke(%module{} = program, inputs, execution) do
    case module.call(program, inputs, execution) do
      {:ok, output, %Execution{} = execution} when is_map(output) ->
        {:ok, output, execution}

      {:error, error, %Execution{} = execution} ->
        {:error, error, execution}

      other ->
        {:error,
         Error.Execution.Callback.exception(
           message:
             "#{inspect(module)}.call/3 must return {:ok, map, execution} or {:error, error, execution}",
           value: other
         ), execution}
    end
  end

  @doc "Returns `true` when two signatures declare the same field names and schemas."
  @spec same_fields?(Signature.t(), Signature.t()) :: boolean()
  def same_fields?(%Signature{} = left, %Signature{} = right) do
    fields(left.inputs) == fields(right.inputs) and fields(left.outputs) == fields(right.outputs)
  end

  defp fields(fields), do: Enum.map(fields, &{&1.name, &1.schema})

  defp check_updates(current, updates) do
    Enum.reduce_while(updates, :ok, fn {name, value}, :ok ->
      case {Map.fetch(current, name), value} do
        {{:ok, %Predictor{signature: old}}, %Predictor{signature: new}} ->
          if same_fields?(old, new),
            do: {:cont, :ok},
            else:
              {:halt, definition_error("predictor #{inspect(name)} changes its declared fields")}

        {{:ok, %Parameter{schema: schema}}, %Parameter{schema: schema}} ->
          {:cont, :ok}

        {{:ok, %Parameter{}}, %Parameter{}} ->
          {:halt, definition_error("parameter #{inspect(name)} changes its schema")}

        {{:ok, _}, _} ->
          {:halt, definition_error("parameter #{inspect(name)} changes its kind")}

        {:error, _} ->
          {:halt, definition_error("unknown parameter #{inspect(name)}")}
      end
    end)
  end

  defp check_program_module(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :call, 3) and
         function_exported?(module, :parameters, 1) and
         function_exported?(module, :put_parameters, 2) and
         function_exported?(module, :signature, 1),
       do: :ok,
       else: callback_error("#{inspect(module)} does not implement Tune", module)
  end

  defp check_parameters(parameters, module) when is_map(parameters) do
    invalid =
      Enum.find(parameters, fn {name, value} ->
        not is_binary(name) or not (match?(%Predictor{}, value) or match?(%Parameter{}, value))
      end)

    case invalid do
      nil ->
        {:ok, parameters}

      {name, _} ->
        callback_error(
          "#{inspect(module)}.parameters/1 has an invalid entry #{inspect(name)}",
          parameters
        )
    end
  end

  defp check_parameters(other, module),
    do: callback_error("#{inspect(module)}.parameters/1 must return a map", other)

  defp check_run_keys(opts) do
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

  defp definition_error(message),
    do: {:error, Error.Invalid.Definition.exception(message: message)}

  defp callback_error(message, value),
    do: {:error, Error.Execution.Callback.exception(message: message, value: value)}
end
