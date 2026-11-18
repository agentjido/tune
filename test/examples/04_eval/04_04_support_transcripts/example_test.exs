defmodule Tune.Examples.SupportTranscriptsTest do
  use ExUnit.Case, async: true

  @moduletag :example

  alias Tune.Examples.SupportTranscripts

  test "keep turn order and continue scoring when a final answer is missing" do
    assert {:ok, report} = SupportTranscripts.transcripts()
    assert report.summaries.resolution.coverage == 0.5
    assert report.summaries.escalation.mean == 1.0
    assert [first, second] = report.observations
    assert Enum.map(first.output, & &1.role) == [:customer, :agent, :agent]
    assert List.last(first.output).text == "Refund sent"
    assert second.score_errors == %{resolution: :missing_final_answer}
    assert second.scores == %{escalation: 1}
  end
end
