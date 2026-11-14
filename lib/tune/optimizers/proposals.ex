defmodule Tune.Optimizers.Proposals do
  @moduledoc """
  Typed internal predictors used by instruction, rule, and value optimizers.

  Every proposal is an ordinary predictor call under the explicit `:proposal`
  role, so it is rendered by that role's adapter, validated against a typed
  output schema, and counted against the run's call limit. Proposed text is
  trimmed, deduplicated, and bounded before use. Proposals see training
  evidence only.
  """

  alias Tune.Example
  alias Tune.Optimizer.Context
  alias Tune.Optimizers.Shared
  alias Tune.Predictor

  @max_text 4_000

  @doc "Returns the maximum accepted length of one proposed text."
  @spec max_text() :: pos_integer()
  def max_text, do: @max_text

  @doc "Proposes up to `n` instruction alternatives for one predictor."
  @spec instructions(Context.t(), Predictor.t(), keyword()) :: {[String.t()], Context.t()}
  def instructions(ctx, %Predictor{} = target, opts) do
    n = Keyword.fetch!(opts, :n)

    inputs = %{
      "task" => describe(target),
      "current_instruction" => target.signature.instructions,
      "attempts" => Keyword.get(opts, :attempts, "None."),
      "evidence" => Keyword.get(opts, :evidence, "None."),
      "count" => n
    }

    {outcome, ctx} = Context.propose(ctx, instruction_predictor(), inputs)
    {clean(outcome, "instructions", n), ctx}
  end

  @doc "Proposes a revised instruction from feedback on training trajectories."
  @spec reflect(Context.t(), String.t(), String.t(), String.t()) ::
          {String.t() | nil, Context.t()}
  def reflect(ctx, task, current, feedback) do
    inputs = %{
      "task" => task,
      "current_instruction" => current,
      "examples_with_feedback" => feedback
    }

    {outcome, ctx} = Context.propose(ctx, reflection_predictor(), inputs)
    {outcome |> clean("new_instruction") |> List.first(), ctx}
  end

  @doc "Derives up to `n` natural-language rules from successful examples."
  @spec rules(Context.t(), String.t(), String.t(), pos_integer()) :: {[String.t()], Context.t()}
  def rules(ctx, task, examples, n) do
    {outcome, ctx} =
      Context.propose(ctx, rules_predictor(), %{
        "task" => task,
        "examples" => examples,
        "count" => n
      })

    {clean(outcome, "rules", n), ctx}
  end

  @doc "Compares good and bad trajectories and returns one rule or advice text."
  @spec contrast(Context.t(), String.t(), String.t(), String.t(), String.t()) ::
          {String.t() | nil, Context.t()}
  def contrast(ctx, task, current, positive, negative) do
    inputs = %{
      "task" => task,
      "current_instruction" => current,
      "successful_examples" => positive,
      "unsuccessful_examples" => negative
    }

    {outcome, ctx} = Context.propose(ctx, contrast_predictor(), inputs)
    {outcome |> clean("feedback") |> List.first(), ctx}
  end

  @doc "Rewrites an instruction from feedback."
  @spec rewrite(Context.t(), String.t(), String.t(), String.t()) ::
          {String.t() | nil, Context.t()}
  def rewrite(ctx, task, current, feedback) do
    inputs = %{"task" => task, "current_instruction" => current, "feedback" => feedback}
    {outcome, ctx} = Context.propose(ctx, rewrite_predictor(), inputs)
    {outcome |> clean("new_instruction") |> List.first(), ctx}
  end

  @doc "Proposes a new list of lessons from the current lessons and training feedback."
  @spec lessons(Context.t(), String.t(), [String.t()], String.t(), pos_integer()) ::
          {[String.t()] | nil, Context.t()}
  def lessons(ctx, task, current, feedback, max) do
    inputs = %{
      "task" => task,
      "current_lessons" => current,
      "examples_with_feedback" => feedback,
      "max_lessons" => max
    }

    case Context.propose(ctx, lessons_predictor(), inputs) do
      {{:ok, %{"lessons" => lessons}}, ctx} -> {Enum.map(lessons, &String.trim/1), ctx}
      {_error, ctx} -> {nil, ctx}
    end
  end

  @doc "Proposes a new JSON-encoded value for a declared parameter."
  @spec value(Context.t(), String.t(), String.t(), String.t(), String.t()) ::
          {String.t() | nil, Context.t()}
  def value(ctx, description, schema, current, feedback) do
    inputs = %{
      "objective" => description,
      "json_schema" => schema,
      "current_value" => current,
      "examples_with_feedback" => feedback
    }

    case Context.propose(ctx, value_predictor(), inputs) do
      {{:ok, %{"new_value" => text}}, ctx} -> {text, ctx}
      {_error, ctx} -> {nil, ctx}
    end
  end

  @doc "Describes a predictor's task from its signature for proposal prompts."
  @spec describe(Predictor.t()) :: String.t()
  def describe(%Predictor{signature: signature}) do
    names = fn fields -> Enum.map_join(fields, ", ", &"`#{&1.name}`") end
    "Inputs: #{names.(signature.inputs)}. Outputs: #{names.(signature.outputs)}."
  end

  @doc "Renders up to `n` training examples as evidence text."
  @spec evidence([Example.t()], non_neg_integer()) :: String.t()
  def evidence([], _n), do: "None."
  def evidence(_examples, 0), do: "None."

  def evidence(examples, n),
    do: examples |> Enum.take(n) |> Enum.map_join("\n\n", &Shared.render_example/1)

  defp clean(outcome, key, n \\ 1)

  defp clean({:ok, outputs}, key, n) do
    outputs
    |> Map.get(key)
    |> List.wrap()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.length(&1) > @max_text))
    |> Enum.uniq()
    |> Enum.take(n)
  end

  defp clean({:error, _error}, _key, _n), do: []

  defp instruction_predictor do
    predictor!(
      "Propose distinct, improved task instructions for a language model. Each instruction must be self-contained and keep the same inputs and outputs. Return exactly `count` instructions.",
      [
        task: Zoi.string(),
        current_instruction: Zoi.string(),
        attempts: Zoi.string(),
        evidence: Zoi.string(),
        count: Zoi.integer()
      ],
      instructions: Zoi.array(Zoi.string())
    )
  end

  defp reflection_predictor do
    predictor!(
      "Read the current instruction and examples of the model's behavior with feedback. Write one improved instruction that fixes the failures while keeping what works.",
      [
        task: Zoi.string(),
        current_instruction: Zoi.string(),
        examples_with_feedback: Zoi.string()
      ],
      new_instruction: Zoi.string()
    )
  end

  defp rules_predictor do
    predictor!(
      "Study the successful examples and write up to `count` concise, general rules that would help solve new examples of the task.",
      [task: Zoi.string(), examples: Zoi.string(), count: Zoi.integer()],
      rules: Zoi.array(Zoi.string())
    )
  end

  defp contrast_predictor do
    predictor!(
      "Compare successful and unsuccessful examples of the task. Explain what the instruction should change so unsuccessful cases succeed.",
      [
        task: Zoi.string(),
        current_instruction: Zoi.string(),
        successful_examples: Zoi.string(),
        unsuccessful_examples: Zoi.string()
      ],
      feedback: Zoi.string()
    )
  end

  defp rewrite_predictor do
    predictor!(
      "Rewrite the instruction to apply the feedback. Keep the same inputs and outputs.",
      [task: Zoi.string(), current_instruction: Zoi.string(), feedback: Zoi.string()],
      new_instruction: Zoi.string()
    )
  end

  defp lessons_predictor do
    predictor!(
      "Update the list of lessons from the examples with feedback. Keep useful lessons, fix or remove wrong ones, and add at most a few new ones. Return at most `max_lessons` short lessons.",
      [
        task: Zoi.string(),
        current_lessons: Zoi.array(Zoi.string()),
        examples_with_feedback: Zoi.string(),
        max_lessons: Zoi.integer()
      ],
      lessons: Zoi.array(Zoi.string())
    )
  end

  defp value_predictor do
    predictor!(
      "Propose an improved value for the objective. Return only the new value as JSON text that matches the JSON schema.",
      [
        objective: Zoi.string(),
        json_schema: Zoi.string(),
        current_value: Zoi.string(),
        examples_with_feedback: Zoi.string()
      ],
      new_value: Zoi.string()
    )
  end

  defp predictor!(instructions, inputs, outputs) do
    {:ok, predictor} =
      Predictor.new(signature: [instructions: instructions, inputs: inputs, outputs: outputs])

    predictor
  end
end
