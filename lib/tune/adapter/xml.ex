defmodule Tune.Adapter.XML do
  @moduledoc """
  DSPy-style XML format with schema-directed field delimiters.

  Each field is wrapped in `<name>` and `</name>`. Values are rendered from the
  declared schema:

    * strings, string enums, and string literals are raw, unescaped text
    * numbers, booleans, null, and non-string literals are JSON text
    * objects with declared keys are nested `<key>` elements in declared order
    * arrays are repeated `<item>` elements
    * string-keyed records are JSON text, because their keys are data

  Parsing follows the same schema. It is not a general XML parser: there is no
  entity expansion, no DTD processing, no attributes, and no namespaces, so
  `&amp;` and `<!DOCTYPE ...>` stay literal text. A string field ends at the
  first matching closing tag, so string values that contain their own closing
  tag are rejected when rendering. Each output field must appear exactly once.

  Options:

    * `:max_reply_bytes` - reply size limit, default 1 000 000
    * `:max_depth` - nesting limit for objects and arrays, default 32

  Differences from DSPy 3.5: field types use JSON names and JSON Schema; nested
  values follow the declared Zoi schema rather than Python type annotations;
  non-string scalars are strict JSON without repair.
  """

  @behaviour Tune.Adapter

  alias ReqLLM.Context
  alias Tune.Adapter.Text
  alias Tune.Error
  alias Tune.Field
  alias Tune.Signature

  @defaults [max_reply_bytes: 1_000_000, max_depth: 32]
  @item "item"

  @impl true
  def normalize_options(opts) do
    Enum.reduce_while(opts, {:ok, @defaults}, fn
      {key, value}, {:ok, acc}
      when key in [:max_reply_bytes, :max_depth] and is_integer(value) and value > 0 ->
        {:cont, {:ok, Keyword.put(acc, key, value)}}

      {key, _value}, _acc when key in [:max_reply_bytes, :max_depth] ->
        {:halt, option_error(key, "must be a positive integer")}

      {key, _value}, _acc ->
        {:halt, option_error(key, "unknown XML adapter option")}
    end)
  end

  @impl true
  def render(%Signature{} = signature, demos, inputs, _opts) do
    with :ok <- check_collisions(signature.inputs, inputs),
         :ok <- Enum.reduce_while(demos, :ok, &check_demo(signature, &1, &2)) do
      messages =
        [Context.system(system_message(signature))] ++
          Enum.flat_map(demos, &demo_messages(signature, &1)) ++
          [Context.user(request_message(signature, inputs))]

      {:ok, %{context: Context.new(messages), output: ReqLLM.Output.text()}}
    end
  end

  @impl true
  def parse(%Signature{} = signature, {:text, text}, opts) when is_binary(text) do
    max_bytes = Keyword.get(opts, :max_reply_bytes, @defaults[:max_reply_bytes])
    max_depth = Keyword.get(opts, :max_depth, @defaults[:max_depth])

    if byte_size(text) > max_bytes do
      parse_error("the reply exceeds #{max_bytes} bytes", nil, text)
    else
      with {:ok, sections} <- top_level(signature, text) do
        Enum.reduce_while(signature.outputs, {:ok, %{}}, fn field, {:ok, acc} ->
          with {:ok, content} <- fetch_section(sections, field.name, text),
               {:ok, value} <- parse_value(field.schema, content, field.name, max_depth) do
            {:cont, {:ok, Map.put(acc, field.name, value)}}
          else
            {:error, error} -> {:halt, {:error, error}}
          end
        end)
      end
    end
  end

  def parse(%Signature{}, reply, _opts),
    do: parse_error("the XML adapter expects a text reply", nil, reply)

  @doc false
  @spec render_value(Zoi.schema(), term()) :: String.t()
  def render_value(schema, value) do
    cond do
      is_nil(value) ->
        "null"

      Field.text_valued?(schema) and is_binary(value) ->
        value

      true ->
        render_structured(non_null(schema, value), value)
    end
  end

  defp render_structured(%Zoi.Types.Map{fields: fields}, value)
       when is_list(fields) and is_map(value) do
    fields
    |> Enum.filter(fn {key, _schema} -> Map.has_key?(value, key) end)
    |> Enum.map_join("\n", fn {key, schema} ->
      element(key, render_value(schema, Map.fetch!(value, key)))
    end)
  end

  defp render_structured(%Zoi.Types.Array{inner: inner}, value) when is_list(value),
    do: Enum.map_join(value, "\n", &element(@item, render_value(inner, &1)))

  defp render_structured(_schema, value) when is_binary(value), do: value
  defp render_structured(_schema, value), do: JSON.encode!(value)

  defp non_null(%Zoi.Types.Union{schemas: schemas} = union, value) do
    Enum.find(schemas, union, fn schema ->
      not match?(%Zoi.Types.Null{}, schema) and match?({:ok, _}, Zoi.parse(schema, value))
    end)
  end

  defp non_null(schema, _value), do: schema

  defp element(name, content), do: "<#{name}>\n#{content}\n</#{name}>"

  defp system_message(signature) do
    structure =
      Enum.map(signature.inputs, &element(&1.name, "{#{&1.name}}")) ++
        Enum.map(signature.outputs, &element(&1.name, placeholder(&1)))

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

  defp placeholder(field) do
    cond do
      Field.text_valued?(field.schema) ->
        Text.placeholder(field)

      structured?(field.schema) ->
        "{#{field.name}}        # note: write object keys as nested elements and array entries as <item> elements, following the JSON schema: " <>
          JSON.encode!(Field.json_schema(field.schema))

      true ->
        Text.placeholder(field)
    end
  end

  defp structured?(%Zoi.Types.Map{fields: fields}) when is_list(fields), do: true
  defp structured?(%Zoi.Types.Array{}), do: true
  defp structured?(%Zoi.Types.Union{schemas: schemas}), do: Enum.any?(schemas, &structured?/1)
  defp structured?(_schema), do: false

  defp marked(fields, values) do
    Enum.map_join(fields, "\n\n", fn field ->
      element(field.name, render_value(field.schema, Map.fetch!(values, field.name)))
    end)
  end

  defp demo_messages(signature, demo) do
    [
      Context.user(marked(signature.inputs, demo.inputs)),
      Context.assistant(marked(signature.outputs, demo.outputs))
    ]
  end

  defp request_message(signature, inputs) do
    order =
      signature.outputs
      |> Enum.map(&"`<#{&1.name}>`")
      |> then(fn [first | rest] ->
        Enum.join(["starting with #{first}" | Enum.map(rest, &"then #{&1}")], ", ")
      end)

    marked(signature.inputs, inputs) <>
      "\n\nRespond with the corresponding output fields wrapped in XML tags, " <> order <> "."
  end

  defp check_demo(signature, demo, :ok) do
    case check_collisions(signature.inputs, demo.inputs) do
      :ok ->
        case check_collisions(signature.outputs, demo.outputs) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end

      error ->
        {:halt, error}
    end
  end

  defp check_collisions(fields, values) do
    Enum.reduce_while(fields, :ok, fn field, :ok ->
      case collision(field.name, field.schema, Map.get(values, field.name)) do
        nil ->
          {:cont, :ok}

        path ->
          {:halt,
           {:error,
            Error.Invalid.Input.exception(
              message: "#{path} contains its own closing tag and cannot be delimited in XML",
              errors: []
            )}}
      end
    end)
  end

  defp collision(name, schema, value) when is_binary(value) do
    if Field.text_valued?(schema) and String.contains?(value, "</#{name}>"), do: name, else: nil
  end

  defp collision(name, schema, value) when is_map(value) do
    case non_null(schema, value) do
      %Zoi.Types.Map{fields: fields} when is_list(fields) ->
        Enum.find_value(fields, fn {key, child} ->
          if Map.has_key?(value, key),
            do: collision_path(name, collision(key, child, Map.fetch!(value, key)))
        end)

      _ ->
        nil
    end
  end

  defp collision(name, schema, value) when is_list(value) do
    case non_null(schema, value) do
      %Zoi.Types.Array{inner: inner} ->
        Enum.find_value(value, &collision_path(name, collision(@item, inner, &1)))

      _ ->
        nil
    end
  end

  defp collision(_name, _schema, _value), do: nil

  defp collision_path(_name, nil), do: nil
  defp collision_path(name, path), do: "#{name}.#{path}"

  defp top_level(signature, text) do
    names = Signature.output_names(signature)
    fields = Map.new(signature.outputs, &{&1.name, &1.schema})
    scan(text, 0, names, fields, %{})
  end

  defp scan(text, offset, names, fields, acc) do
    case next_open(text, offset, names) do
      nil ->
        {:ok, acc}

      {name, content_start} ->
        if Map.has_key?(acc, name) do
          parse_error("output field #{inspect(name)} appears more than once", name, text)
        else
          case close_of(text, name, content_start, Field.text_valued?(fields[name])) do
            {:ok, content_end, next} ->
              content = binary_part(text, content_start, content_end - content_start)
              scan(text, next, names, fields, Map.put(acc, name, content))

            :error ->
              parse_error("output field #{inspect(name)} is not closed", name, text)
          end
        end
    end
  end

  defp next_open(text, offset, names) do
    rest = binary_part(text, offset, byte_size(text) - offset)

    case Regex.run(~r/<([A-Za-z_][A-Za-z0-9_]*)>/, rest, return: :index) do
      nil ->
        nil

      [{start, length}, {name_start, name_length}] ->
        name = binary_part(rest, name_start, name_length)

        if name in names,
          do: {name, offset + start + length},
          else: next_open(text, offset + start + length, names)
    end
  end

  defp close_of(text, name, start, text_valued?) do
    open = "<#{name}>"
    close = "</#{name}>"
    rest = binary_part(text, start, byte_size(text) - start)

    if text_valued? do
      case :binary.match(rest, close) do
        {position, length} -> {:ok, start + position, start + position + length}
        :nomatch -> :error
      end
    else
      matching_close(rest, open, close, 0, 0)
      |> case do
        {:ok, position} -> {:ok, start + position, start + position + byte_size(close)}
        :error -> :error
      end
    end
  end

  defp matching_close(rest, open, close, position, depth) do
    case :binary.matches(rest, [open, close], scope: {position, byte_size(rest) - position}) do
      [] ->
        :error

      [{found, length} | _] ->
        tag = binary_part(rest, found, length)

        cond do
          tag == open -> matching_close(rest, open, close, found + length, depth + 1)
          depth == 0 -> {:ok, found}
          true -> matching_close(rest, open, close, found + length, depth - 1)
        end
    end
  end

  defp fetch_section(sections, name, text) do
    case Map.fetch(sections, name) do
      {:ok, content} -> {:ok, content}
      :error -> parse_error("missing output field #{inspect(name)}", name, text)
    end
  end

  defp parse_value(_schema, _content, path, depth) when depth < 0,
    do: parse_error("#{path} exceeds the nesting limit", path, nil)

  defp parse_value(schema, content, path, depth) do
    trimmed = String.trim(content)

    cond do
      Field.nullable?(schema) and trimmed == "null" ->
        {:ok, nil}

      Field.text_valued?(schema) ->
        {:ok, trimmed}

      true ->
        parse_typed(schema, trimmed, path, depth)
    end
  end

  defp parse_typed(%Zoi.Types.Map{fields: fields}, content, path, depth) when is_list(fields) do
    with {:ok, children} <- children(content, Enum.map(fields, &elem(&1, 0)), path, fields) do
      Enum.reduce_while(fields, {:ok, %{}}, fn {key, schema}, {:ok, acc} ->
        case Map.fetch(children, key) do
          {:ok, [child]} ->
            case parse_value(schema, child, "#{path}.#{key}", depth - 1) do
              {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
              error -> {:halt, error}
            end

          {:ok, [_ | _]} ->
            {:halt, parse_error("#{path}.#{key} appears more than once", path, content)}

          :error ->
            {:cont, {:ok, acc}}
        end
      end)
    end
  end

  defp parse_typed(%Zoi.Types.Array{inner: inner}, content, path, depth) do
    with {:ok, children} <- children(content, [@item], path, [{@item, inner}]) do
      children
      |> Map.get(@item, [])
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {child, index}, {:ok, acc} ->
        case parse_value(inner, child, "#{path}[#{index}]", depth - 1) do
          {:ok, value} -> {:cont, {:ok, [value | acc]}}
          error -> {:halt, error}
        end
      end)
      |> then(fn
        {:ok, values} -> {:ok, Enum.reverse(values)}
        error -> error
      end)
    end
  end

  defp parse_typed(%Zoi.Types.Union{schemas: schemas}, content, path, depth) do
    schemas
    |> Enum.reject(&match?(%Zoi.Types.Null{}, &1))
    |> Enum.find_value(fn schema ->
      with {:ok, value} <- parse_typed(schema, content, path, depth),
           {:ok, value} <- Zoi.parse(schema, value) do
        {:ok, value}
      else
        _ -> nil
      end
    end)
    |> case do
      nil -> parse_error("#{path} matches no allowed type", path, content)
      ok -> ok
    end
  end

  defp parse_typed(_schema, content, path, _depth) do
    case JSON.decode(content) do
      {:ok, value} -> {:ok, value}
      {:error, _} -> parse_error("#{path} is not valid JSON", path, content)
    end
  end

  defp children(content, names, path, fields) do
    schemas = Map.new(fields)
    collect_children(content, 0, names, schemas, path, %{})
  end

  defp collect_children(content, offset, names, schemas, path, acc) do
    case next_open(content, offset, names) do
      nil ->
        {:ok, Map.new(acc, fn {key, values} -> {key, Enum.reverse(values)} end)}

      {name, start} ->
        case close_of(content, name, start, Field.text_valued?(schemas[name])) do
          {:ok, finish, next} ->
            child = binary_part(content, start, finish - start)

            collect_children(
              content,
              next,
              names,
              schemas,
              path,
              Map.update(acc, name, [child], &[child | &1])
            )

          :error ->
            parse_error("#{path}.#{name} is not closed", path, content)
        end
    end
  end

  defp parse_error(message, field, reply),
    do: {:error, Error.Output.Parse.exception(message: message, field: field, reply: reply)}

  defp option_error(option, message),
    do: {:error, Error.Invalid.Option.exception(option: option, message: message)}
end
