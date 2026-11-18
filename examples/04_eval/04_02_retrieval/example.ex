defmodule Tune.Examples.Retrieval do
  @moduledoc "Score saved answers independently for grounding and retrieval order."

  alias Tune.Examples.Support.Offline
  alias Tune.Examples.Support.Transport
  alias Tune.Scores.{ContextPrecision, Faithfulness}

  def run(opts \\ []) do
    support =
      Transport.script([
        {:tool, ~s({"statements":[{"text":"Paris is in France."}]})},
        {:tool, ~s({"supported":true,"reasoning":"A retrieved passage supports the answer."})}
      ])

    relevance =
      Transport.script(
        Keyword.get(opts, :precision_replies, [
          relevance(false, "The passage is unrelated."),
          relevance(true, "The passage locates Paris."),
          relevance(true, "The passage identifies the country.")
        ])
      )

    {:ok, faithfulness} = Faithfulness.new(Offline.judge(support))
    {:ok, precision} = ContextPrecision.new(Offline.judge(relevance) ++ [concurrency: 1])

    [
      %{
        id: "paris",
        input: %{
          user_input: "Where is Paris?",
          retrieved_contexts: [
            "A bicycle has two wheels.",
            "Paris is in France.",
            "Paris is its capital."
          ]
        },
        output: "Paris is in France.",
        expected: "Paris is in France."
      }
    ]
    |> Tune.replay()
    |> Tune.score(:faithfulness, faithfulness)
    |> Tune.score(:precision, precision)
    |> Tune.limit(model_calls: 5)
    |> Tune.evaluate()
  end

  defp relevance(relevant, reasoning),
    do: {:tool, JSON.encode!(%{relevant: relevant, reasoning: reasoning})}
end
