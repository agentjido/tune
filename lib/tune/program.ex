defmodule Tune.Program do
  @moduledoc """
  The contract for a typed Tune program.

  A program is either a `Tune.Predictor` or a struct whose module implements
  this behaviour. Composition stays in ordinary Elixir functions.
  """

  alias Tune.Error
  alias Tune.Execution
  alias Tune.Parameter
  alias Tune.Predictor
  alias Tune.Signature

  @root "root"

  @type t :: Predictor.t() | struct()
  @type parameters :: %{String.t() => Predictor.t() | Parameter.t()}

  @callback signature(program :: struct()) :: Signature.t()
  @callback parameters(program :: struct()) :: parameters()
  @callback put_parameters(program :: struct(), parameters()) :: struct()
  @callback call(program :: struct(), inputs :: map(), Execution.t()) ::
              {:ok, map(), Execution.t()} | {:error, term(), Execution.t()}

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

  Every name must exist. Each replacement must keep its kind and schema.
  """
  @spec replace_parameters(t(), parameters()) :: {:ok, t()} | {:error, Exception.t()}
  def replace_parameters(program, updates) when is_map(updates) do
    with {:ok, current} <- parameters(program),
         :ok <- check_updates(current, updates) do
      put_parameters(program, Map.merge(current, updates))
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

  @doc "Returns true when two signatures have the same field names and schemas."
  @spec same_fields?(Signature.t(), Signature.t()) :: boolean()
  def same_fields?(%Signature{} = left, %Signature{} = right) do
    fields(left.inputs) == fields(right.inputs) and fields(left.outputs) == fields(right.outputs)
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
       else: callback_error("#{inspect(module)} does not implement Tune.Program", module)
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

  defp definition_error(message),
    do: {:error, Error.Invalid.Definition.exception(message: message)}

  defp callback_error(message, value),
    do: {:error, Error.Execution.Callback.exception(message: message, value: value)}
end
