defmodule Tune.Prediction do
  @moduledoc """
  The outcome of one target execution.

  A failed execution keeps its partial prediction in
  `Tune.Error.Execution.Failed`.
  """

  alias Tune.Step

  defstruct output: nil,
            steps: [],
            failures: [],
            calls: %{},
            usage: %{input: 0, output: 0, total: 0},
            metadata: %{}

  @type failure :: %{name: String.t(), role: atom(), error: term()}

  @type t :: %__MODULE__{
          output: term(),
          steps: [Step.t()],
          failures: [failure()],
          calls: %{optional(atom()) => non_neg_integer()},
          usage: %{input: non_neg_integer(), output: non_neg_integer(), total: non_neg_integer()},
          metadata: map()
        }

  @doc "Returns the total attempted managed model calls."
  @spec total_calls(t()) :: non_neg_integer()
  def total_calls(%__MODULE__{calls: calls}), do: calls |> Map.values() |> Enum.sum()

  @doc "Returns provider-reported usage for each step, in call order."
  @spec step_usage(t()) :: [map() | nil]
  def step_usage(%__MODULE__{steps: steps}),
    do: Enum.map(steps, &ReqLLM.Response.usage(&1.response))

  @doc "Sums provider-reported token use across all steps."
  @spec token_totals(t()) :: %{
          input: non_neg_integer(),
          output: non_neg_integer(),
          total: non_neg_integer()
        }
  def token_totals(%__MODULE__{} = prediction) do
    prediction
    |> step_usage()
    |> Enum.reduce(%{input: 0, output: 0, total: 0}, fn usage, acc ->
      usage = usage || %{}

      %{
        input: acc.input + token(usage, :input_tokens),
        output: acc.output + token(usage, :output_tokens),
        total: acc.total + token(usage, :total_tokens)
      }
    end)
  end

  defp token(usage, key) do
    case Map.get(usage, key) || Map.get(usage, Atom.to_string(key)) do
      value when is_integer(value) -> value
      _ -> 0
    end
  end
end
