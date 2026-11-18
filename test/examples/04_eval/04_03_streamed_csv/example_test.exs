defmodule Tune.Examples.StreamedCsvTest do
  use ExUnit.Case, async: true

  @moduletag :example

  alias Tune.Examples.StreamedCSV

  test "score the stream in both directions and retain the malformed row" do
    assert {:ok, report} = StreamedCSV.csv()
    assert %{direction: :maximize, count: 3, mean: mean} = report.summaries.exact_match
    assert_in_delta mean, 2 / 3, 0.0001
    assert report.selected_score == 0.5
    assert %{direction: :maximize, count: 3, coverage: 0.75} = report.summaries.abstention
    assert %{direction: :minimize, count: 3, coverage: 0.75} = report.summaries.cost

    assert %{
             id: "broken",
             status: :error,
             metadata: %{case: %{input: %{input: %{parse_error: _}}}}
           } =
             List.last(report.observations)
  end
end
