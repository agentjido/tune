defmodule Tune.Examples.WorkbenchTest do
  use ExUnit.Case, async: false

  @moduletag :example

  alias Tune.Examples.Workbench

  test "workbench runs replay, search, comparison, and download with retained run evidence" do
    run = Workbench.run()
    assert run.saved.result.summaries.route.mean == 1.0
    assert run.saved.result.calls == %{}
    assert run.missing_split.message =~ "choose a dataset split"
    assert %{source: %{rows: 2}, effective: %{rows: 1}} = run.search.evidence.datasets.train
    assert run.comparison.result.split == :test
    assert run.comparison.result.metrics.route.delta == 1.0
    assert run.comparison.result.metrics.route.paired_count == 1
    assert run.download.status == 200
    assert {:ok, artifact} = Tune.Artifact.decode(run.download.resp_body)
    assert artifact == run.search.artifact
    assert run.rendered =~ "Support router"
    assert run.rendered =~ "<td>1/1</td>"
    refute run.rendered =~ "Edited router"
    assert run.rendered =~ run.comparison.evidence.datasets.test.effective.fingerprint
    refute Process.whereis(Tune.UI.Store)
  end
end
