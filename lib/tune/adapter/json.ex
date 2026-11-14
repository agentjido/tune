defmodule Tune.Adapter.JSON do
  @moduledoc """
  DSPy-style JSON format: marked inputs and a JSON object reply.

  Options:

    * `:mode` - required, `:text` or `:structured`. Text mode requests plain
      text and decodes the reply as one JSON object, optionally inside a single
      Markdown code fence. Structured mode requests a ReqLLM object output with
      the signature's output schema, validated strictly by ReqLLM.

  Both modes take only declared output keys from the object; extra keys are
  ignored and missing keys are errors. There is no JSON repair and no automatic
  switch between modes. Structured provider support belongs to ReqLLM.

  Differences from DSPy 3.5: no `json_repair`, no automatic structured-to-text
  fallback, and JSON type descriptions instead of Python annotations.
  """

  @behaviour Tune.Adapter

  alias ReqLLM.Context
  alias Tune.Adapter.Text
  alias Tune.Error
  alias Tune.Signature

  @fence ~r/\A```(?:json)?[ \t]*\n(.*)\n```\z/s

  @impl true
  def normalize_options(opts) do
    case Keyword.split(opts, [:mode]) do
      {[mode: mode], []} when mode in [:text, :structured] ->
        {:ok, [mode: mode]}

      {[mode: mode], []} ->
        option_error(:mode, "must be :text or :structured, got: #{inspect(mode)}")

      {[], []} ->
        option_error(:mode, "is required")

      {_, [{key, _} | _]} ->
        option_error(key, "unknown JSON adapter option")

      {_, []} ->
        option_error(:mode, "is given more than once")
    end
  end

  @impl true
  def render(%Signature{} = signature, demos, inputs, opts) do
    messages =
      [Context.system(system_message(signature))] ++
        Enum.flat_map(demos, &demo_messages(signature, &1)) ++
        [Context.user(request_message(signature, inputs))]

    {:ok,
     %{context: Context.new(messages), output: output(signature, Keyword.fetch!(opts, :mode))}}
  end

  @impl true
  def parse(%Signature{} = signature, {:text, text}, _opts) when is_binary(text) do
    with {:ok, decoded} <- decode(text) do
      take_outputs(signature, decoded, text)
    end
  end

  def parse(%Signature{} = signature, {:object, object}, _opts) when is_map(object),
    do: take_outputs(signature, object, object)

  def parse(%Signature{}, reply, _opts),
    do: parse_error("unsupported reply #{inspect(reply)}", nil, reply)

  defp output(_signature, :text), do: ReqLLM.Output.text()

  defp output(signature, :structured),
    do: ReqLLM.Output.object(signature.output_schema, name: "outputs")

  defp system_message(signature) do
    inputs = Enum.map_join(signature.inputs, "\n\n", &(Text.header(&1.name) <> "\n{#{&1.name}}"))

    last = length(signature.outputs) - 1

    skeleton =
      "{\n" <>
        (signature.outputs
         |> Enum.with_index()
         |> Enum.map_join("\n", fn {field, index} ->
           skeleton_line(field, if(index == last, do: "", else: ","))
         end)) <> "\n}"

    Enum.join(
      [
        Text.field_descriptions(signature),
        "All interactions will be structured in the following way, with the appropriate values filled in.\n\n" <>
          "Inputs will have the following structure:\n\n" <>
          inputs <>
          "\n\nOutputs will be a JSON object with the following fields.\n\n" <> skeleton,
        Text.objective(signature)
      ],
      "\n"
    )
  end

  defp skeleton_line(field, separator) do
    line = ~s(  "#{field.name}": "{#{field.name}}") <> separator

    case Text.value_requirement(field.schema) do
      nil -> line
      requirement -> line <> "        # note: the value you produce " <> requirement
    end
  end

  defp demo_messages(signature, demo) do
    object =
      signature.outputs
      |> Enum.map(&{&1.name, Map.fetch!(demo.outputs, &1.name)})
      |> Jason.OrderedObject.new()

    [
      Context.user(Text.marked_fields(signature.inputs, demo.inputs)),
      Context.assistant(Jason.encode!(object, pretty: true))
    ]
  end

  defp request_message(signature, inputs) do
    Text.marked_fields(signature.inputs, inputs) <>
      "\n\nRespond with a JSON object in the following order of fields: " <>
      Text.field_order_hint(signature.outputs, &"`#{&1}`", "") <> "."
  end

  defp decode(text) do
    trimmed = String.trim(text)

    body =
      case Regex.run(@fence, trimmed, capture: :all_but_first) do
        [inner] -> inner
        nil -> trimmed
      end

    case Jason.decode(body) do
      {:ok, %{} = object} -> {:ok, object}
      {:ok, _other} -> parse_error("the reply is not a JSON object", nil, text)
      {:error, _} -> parse_error("the reply is not valid JSON", nil, text)
    end
  end

  defp take_outputs(signature, object, reply) do
    Enum.reduce_while(signature.outputs, {:ok, %{}}, fn field, {:ok, acc} ->
      case Map.fetch(object, field.name) do
        {:ok, value} ->
          {:cont, {:ok, Map.put(acc, field.name, value)}}

        :error ->
          {:halt, parse_error("missing output field #{inspect(field.name)}", field.name, reply)}
      end
    end)
  end

  defp parse_error(message, field, reply),
    do: {:error, Error.Output.Parse.exception(message: message, field: field, reply: reply)}

  defp option_error(option, message),
    do: {:error, Error.Invalid.Option.exception(option: option, message: message)}
end
