defmodule Tune.Examples.SupportTranscripts do
  @moduledoc "Score ordered transcript turns independently."

  def transcripts do
    [
      %{
        id: "refund",
        input: %{ticket: "refund", resolution: "Refund sent"},
        output: [
          %{role: :customer, text: "I'd like a refund"},
          %{role: :agent, text: "Escalating to payments"},
          %{role: :agent, text: "Refund sent"}
        ]
      },
      %{
        id: "blocked",
        input: %{ticket: "blocked payment", resolution: "Payment restored"},
        output: [
          %{role: :customer, text: "Payment is blocked"},
          %{role: :agent, text: "Escalating to payments"}
        ]
      }
    ]
    |> Tune.replay()
    |> Tune.score(:resolution, &resolution/2)
    |> Tune.score(:escalation, &escalation/2)
    |> Tune.evaluate()
  end

  defp resolution(row, turns) do
    case List.last(turns) do
      %{role: :agent, text: "Escalating" <> _} -> {:error, :missing_final_answer}
      %{role: :agent, text: text} -> if(text == row.input.resolution, do: 1, else: 0)
      _ -> {:error, :missing_final_answer}
    end
  end

  defp escalation(_row, [%{role: :customer} | turns]) do
    if Enum.any?(turns, &match?(%{role: :agent, text: "Escalating" <> _}, &1)), do: 1, else: 0
  end
end
