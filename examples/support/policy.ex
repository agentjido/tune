defmodule Tune.Examples.Support.Policy do
  @moduledoc "A typed routing policy used by application code."

  @behaviour Tune.Program

  alias Tune.Examples.Support.Offline
  alias Tune.Examples.Support.Transport
  alias Tune.{Execution, Parameter, Signature}

  defstruct [:policy, :standard_queue]

  @initial %{"threshold" => 0.9, "queue" => "risk-review"}
  @selected %{"threshold" => 0.6, "queue" => "risk-review"}

  def new do
    schema = Zoi.object(%{"threshold" => Zoi.float(), "queue" => Zoi.string()})

    {:ok, policy} =
      Parameter.new(schema: schema, value: @initial, description: "Risk routing policy")

    {:ok, standard_queue} = Parameter.new(schema: Zoi.string(), value: "general")
    %__MODULE__{policy: policy, standard_queue: standard_queue}
  end

  @impl true
  def signature(_) do
    {:ok, signature} = Signature.new(inputs: [risk: Zoi.float()], outputs: [queue: Zoi.string()])
    signature
  end

  @impl true
  def parameters(program),
    do: %{"policy" => program.policy, "standard_queue" => program.standard_queue}

  @impl true
  def put_parameters(program, params),
    do: %{program | policy: params["policy"], standard_queue: params["standard_queue"]}

  @impl true
  def call(_, %{"risk" => risk}, execution) do
    {:ok, policy} = Execution.value(execution, "policy")
    {:ok, standard} = Execution.value(execution, "standard_queue")
    queue = if risk >= policy["threshold"], do: policy["queue"], else: standard
    {:ok, %{"queue" => queue}, execution}
  end

  def optimize do
    proposals =
      [
        %{"threshold" => "high", "queue" => "risk-review"},
        @selected
      ]
      |> Enum.map(&Transport.chat(new_value: JSON.encode!(&1)))
      |> Transport.script()

    never = Transport.script([])

    Tune.new(new(), proposal: Offline.model(proposals), model: Offline.model(never))
    |> Tune.data(
      train: [row(0.2, "general"), row(0.7, "risk-review")],
      validation: [row(0.4, "general"), row(0.8, "risk-review")]
    )
    |> Tune.score(
      :routing,
      fn row, output ->
        if output == row.expected,
          do: %{score: 1, feedback: "correct queue"},
          else: %{score: 0, feedback: "lower the review threshold"}
      end,
      argument: :output
    )
    |> Tune.search(:anything, parameter: "policy", max_iterations: 2, minibatch_size: 2)
    |> Tune.limit(model_calls: 6, seed: 2)
    |> Tune.tune()
  end

  defp row(risk, queue), do: %{input: %{risk: risk}, expected: %{queue: queue}}
end
