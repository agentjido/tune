defmodule Tune.Examples.Support.Transport do
  @moduledoc """
  Scripted OpenAI-compatible chat responses through an in-process Plug.

  Requests go through the real public ReqLLM generation path. Each scripted
  reply is served once, in order; every request body is sent to the test
  process as `{:model_request, name, body}`.
  """

  @model %{provider: :openai, id: "gpt-4-turbo", extra: %{wire: %{protocol: "openai_chat"}}}

  def model, do: @model

  @doc "Request options that route ReqLLM through a scripted stub."
  def request_options(stub, extra \\ [])

  def request_options(:unused, extra) do
    request_options({:unused, fn _conn -> raise "unexpected model request" end}, extra)
  end

  def request_options({_name, plug}, extra) do
    [api_key: "test-secret-key", req_http_options: [plug: plug], max_retries: 0] ++ extra
  end

  @doc """
  Scripts replies. Each reply is `{:text, text}`, `{:text, text, finish_reason}`,
  `{:tool, arguments_json}`, or `{:http_error, status, body}`.
  """
  def script(replies) do
    {:ok, agent} = Agent.start_link(fn -> replies end)

    respond_with(fn _body ->
      Agent.get_and_update(agent, fn
        [next | rest] -> {next, rest}
        [] -> {:exhausted, []}
      end)
    end)
  end

  @doc """
  Scripts replies with a function of the decoded request body, for requests
  whose order is not fixed.
  """
  def respond_with(fun) when is_function(fun, 1) do
    name = make_ref()
    test_pid = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = JSON.decode!(body)
      send(test_pid, {:model_request, name, decoded})
      respond(conn, fun.(decoded))
    end

    {name, plug}
  end

  @doc "Returns the text of the last user message in a request body."
  def last_user_text(body) do
    body["messages"]
    |> Enum.filter(&(&1["role"] == "user"))
    |> List.last()
    |> prompt_text_of()
  end

  defp prompt_text_of(%{"content" => content}) when is_binary(content), do: content

  defp prompt_text_of(%{"content" => parts}) when is_list(parts),
    do: Enum.map_join(parts, "", &(&1["text"] || ""))

  defp prompt_text_of(_), do: ""

  defp respond(conn, {:text, text}), do: respond(conn, {:text, text, "stop"})

  defp respond(conn, {:text, text, finish_reason}) do
    json(conn, 200, %{
      "id" => "cmpl_#{System.unique_integer([:positive])}",
      "model" => "gpt-4-turbo",
      "choices" => [
        %{
          "message" => %{"role" => "assistant", "content" => text},
          "finish_reason" => finish_reason
        }
      ],
      "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
    })
  end

  defp respond(conn, {:tool, arguments}) do
    json(conn, 200, %{
      "id" => "cmpl_#{System.unique_integer([:positive])}",
      "model" => "gpt-4-turbo",
      "choices" => [
        %{
          "message" => %{
            "role" => "assistant",
            "tool_calls" => [
              %{
                "id" => "call_1",
                "type" => "function",
                "function" => %{"name" => "structured_output", "arguments" => arguments}
              }
            ]
          },
          "finish_reason" => "tool_calls"
        }
      ],
      "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
    })
  end

  defp respond(conn, {:http_error, status, body}) do
    json(conn, status, body)
  end

  defp respond(conn, :exhausted) do
    json(conn, 500, %{"error" => %{"message" => "no scripted reply left"}})
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, JSON.encode!(body))
  end

  @doc "Builds a Chat-format text reply from an ordered list of field values."
  def chat(fields) do
    body =
      Enum.map_join(fields, "\n\n", fn {name, value} ->
        text = if is_binary(value), do: value, else: JSON.encode!(value)
        "[[ ## #{name} ## ]]\n#{text}"
      end)

    {:text, body <> "\n\n[[ ## completed ## ]]"}
  end

  @doc "Returns the text of every message in a request body, joined."
  def prompt_text(body) do
    body["messages"]
    |> Enum.map_join("\n", fn
      %{"content" => content} when is_binary(content) -> content
      %{"content" => parts} when is_list(parts) -> Enum.map_join(parts, "", &(&1["text"] || ""))
      _ -> ""
    end)
  end

  @doc "Returns the request bodies received so far for a stub."
  def requests({name, _plug}) do
    receive_all(name, [])
  end

  defp receive_all(name, acc) do
    receive do
      {:model_request, ^name, body} -> receive_all(name, [body | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
