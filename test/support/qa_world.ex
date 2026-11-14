defmodule Tune.TestSupport.QAWorld do
  @moduledoc """
  A scripted model for the grounded QA example, in Chat, JSON, or XML format.

  Replies depend only on the request: the extraction predictor returns the
  passages whose text starts with "About"; the answering predictor answers
  from the facts it received. The request format is detected from the
  rendered prompt and the reply uses the same format.

  Options:

    * `:overrides` - per question: `:fail_extract`, `:fail_answer`, or `{:answer, text}`
    * `:quality` - `fn prompt, answer -> answer end` or `fn prompt, answer, body -> answer end`
      to simulate the effect of instructions, demos, or lessons on the answer
  """

  alias Tune.TestSupport.Transport

  @doc "Builds QA rows from `{question, subject, answer}` triples."
  def rows(items) do
    Enum.map(items, fn {question, subject, answer} ->
      %{
        inputs: %{context: passages(subject, answer), question: question},
        labels: %{answer: answer, sources: ["#{subject}-1"]}
      }
    end)
  end

  def passages(subject, answer) do
    [
      %{"id" => "#{subject}-1", "text" => "About #{subject}: #{answer}."},
      %{"id" => "noise-#{subject}", "text" => "An unrelated note."}
    ]
  end

  @doc "Returns a stub that answers QA requests."
  def stub(opts \\ []) do
    overrides = Keyword.get(opts, :overrides, %{})
    quality = quality(Keyword.get(opts, :quality, fn _prompt, answer -> answer end))

    Transport.respond_with(fn body ->
      prompt = Transport.prompt_text(body)
      user = Transport.last_user_text(body)
      format = format(prompt)
      question = text_field(format, user, "question")

      cond do
        has_field?(format, user, "context") ->
          case Map.get(overrides, question) do
            :fail_extract ->
              {:text, "I cannot find facts."}

            _ ->
              facts =
                for p <- passages_field(format, user),
                    String.starts_with?(p["text"], "About"),
                    do: %{"text" => p["text"], "source" => p["id"]}

              reply(format, facts: facts)
          end

        has_field?(format, user, "guidance") ->
          case Map.get(overrides, question) do
            :fail_answer ->
              {:text, "No idea."}

            {:answer, text} ->
              reply(format, answer: text, sources: [])

            _ ->
              {answer, sources} =
                case facts_field(format, user) do
                  [%{"text" => text, "source" => source} | _] ->
                    [_, answer] = Regex.run(~r/: (.*)\.$/, text)
                    {answer, [source]}

                  [] ->
                    {"unknown", []}
                end

              reply(format, answer: quality.(prompt, answer, body), sources: sources)
          end

        true ->
          {:text, "unexpected request"}
      end
    end)
  end

  @doc "Exact-answer metric with feedback."
  def metric(example, result) do
    if result.output["answer"] == example.labels["answer"] do
      %{score: 1.0, feedback: "correct"}
    else
      %{
        score: 0.0,
        feedback: "expected #{example.labels["answer"]}, got #{result.output["answer"]}"
      }
    end
  end

  @doc "Returns `true` when the request includes demonstrations."
  def demos?(body), do: Enum.any?(body["messages"], &(&1["role"] == "assistant"))

  defp quality(fun) when is_function(fun, 3), do: fun

  defp quality(fun) when is_function(fun, 2),
    do: fn prompt, answer, _body -> fun.(prompt, answer) end

  defp format(prompt) do
    cond do
      prompt =~ "Outputs will be a JSON object" -> :json
      prompt =~ "wrapped in XML tags" -> :xml
      true -> :chat
    end
  end

  defp has_field?(:xml, user, name), do: user =~ "<#{name}>"
  defp has_field?(_format, user, name), do: user =~ "[[ ## #{name} ## ]]"

  defp text_field(:xml, user, name) do
    case Regex.run(~r/<#{name}>\n(.*?)\n<\/#{name}>/s, user) do
      [_, value] -> value
      nil -> nil
    end
  end

  defp text_field(_format, user, name) do
    case Regex.run(~r/\[\[ ## #{name} ## \]\]\n(.*?)(?=\n\n\[\[ ## |\n\nRespond with|\z)/s, user) do
      [_, value] -> value
      nil -> nil
    end
  end

  defp passages_field(:xml, user) do
    section = text_field(:xml, user, "context") || ""
    pattern = ~r/<item>\s*<id>\s*(.*?)\s*<\/id>\s*<text>\s*(.*?)\s*<\/text>\s*<\/item>/s
    for [_, id, text] <- Regex.scan(pattern, section), do: %{"id" => id, "text" => text}
  end

  defp passages_field(format, user), do: Jason.decode!(text_field(format, user, "context"))

  defp facts_field(:xml, user) do
    section = text_field(:xml, user, "facts") || ""
    pattern = ~r/<item>\s*<source>\s*(.*?)\s*<\/source>\s*<text>\s*(.*?)\s*<\/text>\s*<\/item>/s

    for [_, source, text] <- Regex.scan(pattern, section),
        do: %{"source" => source, "text" => text}
  end

  defp facts_field(format, user), do: Jason.decode!(text_field(format, user, "facts"))

  defp reply(:chat, fields), do: Transport.chat(fields)

  defp reply(:json, fields) do
    {:text,
     fields
     |> Enum.map(fn {k, v} -> {Atom.to_string(k), v} end)
     |> Jason.OrderedObject.new()
     |> Jason.encode!()}
  end

  defp reply(:xml, fields) do
    {:text,
     Enum.map_join(fields, "\n\n", fn
       {:facts, facts} ->
         items =
           Enum.map_join(
             facts,
             "\n",
             &"<item>\n<source>#{&1["source"]}</source>\n<text>#{&1["text"]}</text>\n</item>"
           )

         "<facts>\n#{items}\n</facts>"

       {:sources, sources} ->
         "<sources>\n#{Enum.map_join(sources, "\n", &"<item>#{&1}</item>")}\n</sources>"

       {name, value} ->
         "<#{name}>\n#{value}\n</#{name}>"
     end)}
  end
end
