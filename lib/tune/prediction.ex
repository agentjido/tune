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

  @doc false
  def successful_models(%__MODULE__{metadata: %{responses: responses}}) do
    for %{model: model, role: role} <- responses,
        is_binary(model),
        do: %{role: role, model: model}
  end

  def successful_models(%__MODULE__{steps: steps}) do
    for step <- steps,
        model = response_model(step.response, nil),
        not is_nil(model),
        do: %{role: step.role || :target, model: model}
  end

  def successful_models(nil), do: []

  @doc false
  def response_model(%ReqLLM.Response{error: nil, model: model}, configured)
      when is_binary(model) and model != "" do
    with id when is_binary(id) <- configured,
         [provider, _id] <- String.split(id, ":", parts: 2),
         false <- String.starts_with?(model, provider <> ":") do
      provider <> ":" <> model
    else
      _ -> model
    end
  end

  def response_model(_response, _configured), do: nil

  @doc "Sums provider-reported token use across all steps."
  @spec token_totals(t()) :: %{
          input: non_neg_integer(),
          output: non_neg_integer(),
          total: non_neg_integer()
        }
  def token_totals(%__MODULE__{} = prediction) do
    {tokens, _cost} = prediction |> call_usage() |> usage_totals()
    tokens
  end

  @doc false
  def call_usage(%__MODULE__{metadata: %{responses: responses}}),
    do: Enum.map(responses, & &1.usage)

  def call_usage(%__MODULE__{} = prediction), do: step_usage(prediction)
  def call_usage(nil), do: []

  @doc false
  def usage_totals(usages) do
    Enum.reduce(usages, {%{input: 0, output: 0, total: 0}, nil}, fn usage, {tokens, cost} ->
      usage = usage || %{}
      amount = Map.get(usage, :total_cost) || Map.get(usage, "total_cost")

      tokens = %{
        input: tokens.input + token(usage, :input_tokens),
        output: tokens.output + token(usage, :output_tokens),
        total: tokens.total + token(usage, :total_tokens)
      }

      cost = if is_number(amount), do: (cost || 0) + amount, else: cost
      {tokens, cost}
    end)
  end

  defp token(usage, key) do
    case Map.get(usage, key) || Map.get(usage, Atom.to_string(key)) do
      value when is_integer(value) -> value
      _ -> 0
    end
  end
end
