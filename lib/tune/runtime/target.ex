defmodule Tune.Runtime.Target do
  @moduledoc false

  alias Tune.Error
  alias Tune.Runtime

  @enforce_keys [:program, :options]
  defstruct [:program, :options]

  @type t :: %__MODULE__{program: Tune.Program.t(), options: keyword()}

  @spec new(Tune.Program.t(), keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def new(program, options) do
    with {:ok, options} <- normalize_options(options),
         {:ok, _parameters} <- Tune.Program.parameters(program),
         {:ok, _signature} <- Tune.Program.signature(program) do
      {:ok, %__MODULE__{program: program, options: options}}
    end
  end

  @spec run(t(), map(), keyword()) :: term()
  def run(%__MODULE__{} = target, input, opts \\ []) do
    options =
      target.options
      |> Keyword.put(:role, Keyword.get(opts, :role, Keyword.get(target.options, :role, :target)))
      |> put_allowance(Keyword.get(opts, :max_model_calls))

    with {:ok, execution} <- Runtime.new_execution(target.program, options) do
      case Runtime.run_with(target.program, input, execution) do
        {:ok, prediction} ->
          {:ok, prediction.output, prediction}

        {:error, %Error.Execution.Failed{result: prediction} = error} ->
          {:error, error, prediction}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp put_allowance(options, nil), do: options
  defp put_allowance(options, allowance), do: Keyword.put(options, :max_model_calls, allowance)

  defp normalize_options(options) do
    if Keyword.has_key?(options, :models),
      do: {:ok, options},
      else: Runtime.normalize_options(options)
  end
end
