defmodule Tune.Optimizers.Shared do
  @moduledoc false

  alias Tune
  alias Tune.Demo
  alias Tune.Example
  alias Tune.Parameter
  alias Tune.Prediction
  alias Tune.Predictor
  alias Tune.Signature

  @spec predictors(Tune.t()) :: [{String.t(), Predictor.t()}]
  def predictors(program) do
    {:ok, parameters} = Tune.Program.parameters(program)

    parameters
    |> Enum.filter(fn {_name, value} -> match?(%Predictor{}, value) end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  @spec values(Tune.t()) :: [{String.t(), Parameter.t()}]
  def values(program) do
    {:ok, parameters} = Tune.Program.parameters(program)

    parameters
    |> Enum.filter(fn {_name, value} -> match?(%Parameter{}, value) end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  @spec labeled_demo(Predictor.t(), Example.t()) :: {:ok, Demo.t()} | :error
  def labeled_demo(%Predictor{signature: signature}, %Example{inputs: inputs, labels: labels}) do
    fields = Map.merge(labels, inputs)
    input_names = Signature.input_names(signature)
    output_names = Signature.output_names(signature)

    if Enum.all?(input_names ++ output_names, &Map.has_key?(fields, &1)) do
      case Demo.new(signature, %{
             inputs: Map.take(fields, input_names),
             outputs: Map.take(fields, output_names)
           }) do
        {:ok, demo} -> {:ok, demo}
        {:error, _} -> :error
      end
    else
      :error
    end
  end

  @spec trajectory_demos(Prediction.t(), [String.t()]) :: %{String.t() => Demo.t()}
  def trajectory_demos(%Prediction{steps: steps}, names) do
    steps
    |> Enum.filter(&(&1.name in names))
    |> Enum.reduce(%{}, fn step, acc ->
      Map.put(acc, step.name, %Demo{inputs: step.inputs, outputs: step.outputs})
    end)
  end

  @spec without_row_demos(Tune.t(), Example.t()) :: Tune.t()
  def without_row_demos(program, %Example{} = example) do
    updates =
      program
      |> predictors()
      |> Map.new(fn {name, predictor} ->
        names = Signature.input_names(predictor.signature)
        fields = Map.merge(example.labels, example.inputs)
        row_inputs = Map.take(fields, names)
        {name, %{predictor | demos: Enum.reject(predictor.demos, &(&1.inputs == row_inputs))}}
      end)

    {:ok, program} = Tune.Program.replace_parameters(program, updates)
    program
  end

  @spec put_demos(Tune.t(), %{String.t() => [Demo.t()]}) :: Tune.t()
  def put_demos(program, demos_by_name) do
    {:ok, parameters} = Tune.Program.parameters(program)

    updates =
      Map.new(demos_by_name, fn {name, demos} ->
        {name, %{Map.fetch!(parameters, name) | demos: demos}}
      end)

    {:ok, program} = Tune.Program.replace_parameters(program, updates)
    program
  end

  @spec put_instructions(Tune.t(), %{String.t() => String.t()}) ::
          {:ok, Tune.t()} | {:error, Exception.t()}
  def put_instructions(program, instructions_by_name) do
    {:ok, parameters} = Tune.Program.parameters(program)

    instructions_by_name
    |> Enum.reduce_while({:ok, %{}}, fn {name, text}, {:ok, acc} ->
      case Predictor.put_instructions(Map.fetch!(parameters, name), text) do
        {:ok, predictor} -> {:cont, {:ok, Map.put(acc, name, predictor)}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, updates} -> Tune.Program.replace_parameters(program, updates)
      error -> error
    end
  end

  @spec put_value(Tune.t(), String.t(), term()) :: {:ok, Tune.t()} | {:error, Exception.t()}
  def put_value(program, name, value) do
    {:ok, parameters} = Tune.Program.parameters(program)

    with {:ok, parameter} <- Parameter.put_value(Map.fetch!(parameters, name), value) do
      Tune.Program.replace_parameters(program, %{name => parameter})
    end
  end

  @spec instructions(Tune.t()) :: %{String.t() => String.t()}
  def instructions(program),
    do: Map.new(predictors(program), fn {name, p} -> {name, p.signature.instructions} end)

  @spec render_example(Example.t()) :: String.t()
  def render_example(%Example{inputs: inputs, labels: labels}) do
    "inputs: " <> Example.canonical_json(inputs) <> "\nlabels: " <> Example.canonical_json(labels)
  end

  @spec render_step(Tune.Step.t()) :: String.t()
  def render_step(step) do
    "inputs: " <>
      Example.canonical_json(step.inputs) <> "\noutputs: " <> Example.canonical_json(step.outputs)
  end

  @spec require_options(keyword(), [atom()], keyword()) ::
          {:ok, keyword()} | {:error, Exception.t()}
  def require_options(opts, allowed, defaults) do
    case Keyword.keys(opts) -- allowed do
      [] ->
        {:ok, Keyword.merge(defaults, opts)}

      [key | _] ->
        {:error,
         Tune.Error.Invalid.Option.exception(
           option: key,
           message: "unknown optimizer option"
         )}
    end
  end

  @spec positive(keyword(), atom()) :: :ok | {:error, Exception.t()}
  def positive(opts, key) do
    case Keyword.get(opts, key) do
      value when is_integer(value) and value > 0 -> :ok
      other -> option_error(key, "must be a positive integer, got: #{inspect(other)}")
    end
  end

  @spec non_negative(keyword(), atom()) :: :ok | {:error, Exception.t()}
  def non_negative(opts, key) do
    case Keyword.get(opts, key) do
      value when is_integer(value) and value >= 0 -> :ok
      other -> option_error(key, "must be a nonnegative integer, got: #{inspect(other)}")
    end
  end

  @spec number_or_nil(keyword(), atom()) :: :ok | {:error, Exception.t()}
  def number_or_nil(opts, key) do
    case Keyword.get(opts, key) do
      nil -> :ok
      value when is_number(value) -> :ok
      other -> option_error(key, "must be a number, got: #{inspect(other)}")
    end
  end

  @spec option_error(atom(), String.t()) :: {:error, Exception.t()}
  def option_error(key, message),
    do: {:error, Tune.Error.Invalid.Option.exception(option: key, message: message)}

  @spec with_checks([(-> :ok | {:error, Exception.t()})]) :: :ok | {:error, Exception.t()}
  def with_checks(checks) do
    Enum.reduce_while(checks, :ok, fn check, :ok ->
      case check.() do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
