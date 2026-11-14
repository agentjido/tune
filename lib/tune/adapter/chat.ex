defmodule Tune.Adapter.Chat do
  @moduledoc """
  DSPy-style Chat format with `[[ ## field ## ]]` markers.

  The system message lists typed fields, shows the marker structure, and states
  the instructions. Demonstrations are user/assistant message pairs. The reply
  must contain each output marker exactly once; text before the first marker,
  the `completed` marker, and markers for other names are ignored. String
  fields use the trimmed text verbatim; other fields are decoded as JSON.

  Differences from DSPy 3.5: field types are described with JSON type names and
  JSON Schema instead of Python annotations, non-string values are decoded as
  strict JSON without repair or Python literal evaluation, and markers are
  recognized with any spaces or tabs around `##` (for example
  `[[ ## label ##]]`, which local models emit). Values are never altered.

  The adapter has no options.
  """

  @behaviour Tune.Adapter

  alias ReqLLM.Context
  alias Tune.Adapter.Text
  alias Tune.Error
  alias Tune.Signature

  @header ~r/\[\[[ \t]*##[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*##[ \t]*\]\]/

  @impl true
  def normalize_options([]), do: {:ok, []}

  def normalize_options([{key, _} | _]),
    do:
      {:error,
       Error.Invalid.Option.exception(option: key, message: "unknown Chat adapter option")}

  @impl true
  def render(%Signature{} = signature, demos, inputs, _opts) do
    messages =
      [Context.system(system_message(signature))] ++
        Enum.flat_map(demos, &demo_messages(signature, &1)) ++
        [Context.user(request_message(signature, inputs))]

    {:ok, %{context: Context.new(messages), output: ReqLLM.Output.text()}}
  end

  @impl true
  def parse(%Signature{} = signature, {:text, text}, _opts) when is_binary(text) do
    with {:ok, sections} <- sections(signature, text) do
      Enum.reduce_while(signature.outputs, {:ok, %{}}, fn field, {:ok, acc} ->
        case Map.fetch(sections, field.name) do
          {:ok, value_text} ->
            case Text.decode_field(field, value_text) do
              {:ok, value} -> {:cont, {:ok, Map.put(acc, field.name, value)}}
              {:error, error} -> {:halt, {:error, error}}
            end

          :error ->
            {:halt, parse_error("missing output field #{inspect(field.name)}", field.name, text)}
        end
      end)
    end
  end

  def parse(%Signature{}, reply, _opts),
    do: parse_error("the Chat adapter expects a text reply", nil, reply)

  defp system_message(signature) do
    structure =
      Enum.map(signature.inputs, &(Text.header(&1.name) <> "\n{#{&1.name}}")) ++
        Enum.map(signature.outputs, &(Text.header(&1.name) <> "\n" <> Text.placeholder(&1))) ++
        [Text.header("completed")]

    Enum.join(
      [
        Text.field_descriptions(signature),
        "All interactions will be structured in the following way, with the appropriate values filled in.\n\n" <>
          Enum.join(structure, "\n\n"),
        Text.objective(signature)
      ],
      "\n"
    )
  end

  defp demo_messages(signature, demo) do
    [
      Context.user(Text.marked_fields(signature.inputs, demo.inputs)),
      Context.assistant(
        Text.marked_fields(signature.outputs, demo.outputs) <> "\n\n" <> Text.header("completed")
      )
    ]
  end

  defp request_message(signature, inputs) do
    hint =
      Text.field_order_hint(
        signature.outputs,
        &"`#{Text.header(&1)}`",
        "starting with the field "
      )

    Text.marked_fields(signature.inputs, inputs) <>
      "\n\nRespond with the corresponding output fields, " <>
      hint <> ", and then ending with the marker for `[[ ## completed ## ]]`."
  end

  defp sections(signature, text) do
    names = Signature.output_names(signature)
    matches = Regex.scan(@header, text, return: :index)

    bounds =
      matches
      |> Enum.with_index()
      |> Enum.map(fn {[{start, length}, {name_start, name_length}], index} ->
        content_start = start + length

        content_end =
          case Enum.at(matches, index + 1) do
            [{next_start, _} | _] -> next_start
            nil -> byte_size(text)
          end

        {binary_part(text, name_start, name_length),
         text |> binary_part(content_start, content_end - content_start) |> String.trim()}
      end)

    Enum.reduce_while(bounds, {:ok, %{}}, fn {name, content}, {:ok, acc} ->
      cond do
        name not in names ->
          {:cont, {:ok, acc}}

        Map.has_key?(acc, name) ->
          {:halt, parse_error("output field #{inspect(name)} appears more than once", name, text)}

        true ->
          {:cont, {:ok, Map.put(acc, name, content)}}
      end
    end)
  end

  defp parse_error(message, field, reply),
    do: {:error, Error.Output.Parse.exception(message: message, field: field, reply: reply)}
end
