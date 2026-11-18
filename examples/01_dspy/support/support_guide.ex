defmodule Tune.Examples.Support.SupportGuide do
  @moduledoc "Predict support urgency with a learned instruction or a bounded playbook."

  @behaviour Tune.Program

  alias Tune.Examples.Support.Offline
  alias Tune.Examples.Support.Transport
  alias Tune.{Execution, Parameter, Predictor, Signature}

  defstruct [:classify, :urgency, :lessons]

  @lesson "Urgent when a payment is blocked."
  @initial "Assess the urgency of the ticket."

  def new do
    {:ok, classify} =
      Predictor.new(signature: [inputs: [ticket: Zoi.string()], outputs: [issue: Zoi.string()]])

    {:ok, urgency} =
      Predictor.new(
        signature: [
          instructions: @initial,
          inputs: [ticket: Zoi.string(), issue: Zoi.string(), lessons: Zoi.string()],
          outputs: [urgency: Zoi.enum(["routine", "urgent"])]
        ]
      )

    {:ok, lessons} = Parameter.new(schema: Zoi.array(Zoi.string()), value: [])
    %__MODULE__{classify: classify, urgency: urgency, lessons: lessons}
  end

  @impl true
  def signature(_) do
    {:ok, signature} =
      Signature.new(
        inputs: [ticket: Zoi.string()],
        outputs: [urgency: Zoi.enum(["routine", "urgent"])]
      )

    signature
  end

  @impl true
  def parameters(program),
    do: %{
      "classify" => program.classify,
      "urgency" => program.urgency,
      "lessons" => program.lessons
    }

  @impl true
  def put_parameters(program, values),
    do: %{
      program
      | classify: values["classify"],
        urgency: values["urgency"],
        lessons: values["lessons"]
    }

  @impl true
  def call(_program, %{"ticket" => ticket} = inputs, execution) do
    with {:ok, %{"issue" => issue}, execution} <- Execution.predict(execution, "classify", inputs) do
      {:ok, lessons} = Execution.value(execution, "lessons")

      Execution.predict(execution, "urgency", %{
        "ticket" => ticket,
        "issue" => issue,
        "lessons" => Enum.join(lessons, "\n")
      })
    end
  end

  def avatar(opts \\ []) do
    proposal =
      Transport.respond_with(fn body ->
        if Transport.last_user_text(body) =~ "[[ ## successful_examples ## ]]",
          do: Transport.chat(feedback: "Blocked payments were classified as routine."),
          else: Transport.chat(new_instruction: @lesson)
      end)

    study(Keyword.get(opts, :train, train()), proposal)
    |> Tune.search(:avatar,
      predictor: "urgency",
      upper_bound: 1.0,
      lower_bound: 0.0,
      max_iters: 1
    )
    |> Tune.tune()
    |> then(&%{result: &1, requests: Transport.requests(proposal)})
  end

  def playbook(lessons \\ [@lesson]) do
    proposal = Transport.respond_with(fn _ -> Transport.chat(lessons: lessons) end)

    study(train(), proposal)
    |> Tune.search(:playbook, parameter: "lessons", rounds: 1, max_new: 1, max_lessons: 2)
    |> Tune.tune()
  end

  def row(ticket, urgency), do: %{input: %{ticket: ticket}, expected: %{urgency: urgency}}

  defp train do
    [row("Routine invoice request", "routine"), row("Payment blocked before closing", "urgent")]
  end

  defp study(train, proposal) do
    target =
      Transport.respond_with(fn body ->
        dialogue = Transport.last_user_text(body)

        if Offline.field(dialogue, "issue") do
          prompt = Transport.prompt_text(body)
          urgent? = prompt =~ @lesson and dialogue =~ ~r/payment blocked/i
          harmful? = prompt =~ "Escalate everything."
          Transport.chat(urgency: if(urgent? or harmful?, do: "urgent", else: "routine"))
        else
          Transport.chat(issue: "payments")
        end
      end)

    Tune.new(new(), model: Offline.model(target), proposal: Offline.model(proposal))
    |> Tune.data(
      train: train,
      validation: [
        row("Payment blocked at checkout", "urgent"),
        row("Routine receipt request", "routine"),
        row("Routine balance request", "routine")
      ]
    )
    |> Tune.score(
      :urgency,
      fn row, output ->
        if output["urgency"] == row.expected["urgency"], do: 1, else: 0
      end,
      argument: :output
    )
    |> Tune.limit(model_calls: 90, seed: 4)
  end
end
