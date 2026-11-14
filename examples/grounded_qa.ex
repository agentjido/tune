defmodule Tune.Examples.GroundedQA do
  @moduledoc """
  Two-step grounded question answering.

  `extract` selects facts with source identifiers from supplied passages.
  `answer` answers from those facts and cites sources. A declared `lessons`
  parameter holds learned guidance that application code passes to `answer`.
  """

  @behaviour Tune

  alias Tune.Execution
  alias Tune.Parameter
  alias Tune.Predictor
  alias Tune.Signature

  defstruct [:extract, :answer, :lessons]

  @passage Zoi.object(%{"id" => Zoi.string(), "text" => Zoi.string()})
  @fact Zoi.object(%{"text" => Zoi.string(), "source" => Zoi.string()})

  @doc "Builds the program with empty demonstrations and no lessons."
  def new do
    {:ok, extract} =
      Predictor.new(
        signature: [
          instructions: "Select the facts from the passages that help answer the question.",
          inputs: [
            context: Zoi.array(@passage, description: "Passages with source identifiers"),
            question: Zoi.string()
          ],
          outputs: [facts: Zoi.array(@fact, description: "Relevant facts with their source id")]
        ]
      )

    {:ok, answer} =
      Predictor.new(
        signature: [
          instructions: "Answer the question using only the facts. Cite the source ids you used.",
          inputs: [
            question: Zoi.string(),
            facts: Zoi.array(@fact),
            guidance: Zoi.string(description: "Lessons learned from earlier questions")
          ],
          outputs: [answer: Zoi.string(), sources: Zoi.array(Zoi.string())]
        ]
      )

    {:ok, lessons} = Parameter.new(schema: Zoi.array(Zoi.string()), value: [])

    %__MODULE__{extract: extract, answer: answer, lessons: lessons}
  end

  @impl true
  def signature(_program) do
    {:ok, signature} =
      Signature.new(
        inputs: [context: Zoi.array(@passage), question: Zoi.string()],
        outputs: [answer: Zoi.string(), sources: Zoi.array(Zoi.string())]
      )

    signature
  end

  @impl true
  def parameters(program) do
    %{"extract" => program.extract, "answer" => program.answer, "lessons" => program.lessons}
  end

  @impl true
  def put_parameters(program, parameters) do
    %{
      program
      | extract: Map.fetch!(parameters, "extract"),
        answer: Map.fetch!(parameters, "answer"),
        lessons: Map.fetch!(parameters, "lessons")
    }
  end

  @impl true
  def call(_program, inputs, execution) do
    with {:ok, %{"facts" => facts}, execution} <- Execution.predict(execution, "extract", inputs),
         {:ok, lessons} <- Execution.value(execution, "lessons") |> with_execution(execution) do
      Execution.predict(execution, "answer", %{
        "question" => inputs["question"],
        "facts" => facts,
        "guidance" => guidance(lessons)
      })
    end
  end

  defp with_execution({:ok, value}, _execution), do: {:ok, value}
  defp with_execution({:error, error}, execution), do: {:error, error, execution}

  defp guidance([]), do: "None."
  defp guidance(lessons), do: Enum.map_join(lessons, "\n", &("- " <> &1))
end
