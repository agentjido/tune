defmodule Tune.Examples.RetrievalTest do
  @moduledoc "Example tests for independent grounding and ranking scores."
  use ExUnit.Case, async: true

  @moduletag :example

  alias Tune.Examples.Retrieval

  test "a fully supported answer can come from poorly ranked contexts" do
    assert {:ok, report} = Retrieval.run()
    assert report.summaries.faithfulness.mean == 1.0
    assert_in_delta report.summaries.precision.mean, 0.5833, 0.001
    assert report.calls == %{judge: 5}
  end

  test "a failed ranking judge costs a call and preserves the grounding score" do
    failure = {:http_error, 422, %{"error" => %{"message" => "scripted ranking failure"}}}
    reply = {:tool, ~s({"relevant":true,"reasoning":"The passage supports the answer."})}
    assert {:ok, report} = Retrieval.run(precision_replies: [failure, reply, reply])
    assert report.calls == %{judge: 5}
    assert report.summaries.faithfulness.mean == 1.0
    assert report.summaries.precision.count == 0
    assert [%{id: "paris", status: :error, score_errors: %{precision: _}}] = report.observations
  end
end
