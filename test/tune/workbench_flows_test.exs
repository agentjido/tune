defmodule Tune.WorkbenchFlowsTest do
  use ExUnit.Case, async: false

  alias Tune.Examples.Support.Transport
  alias Tune.UI.ArtifactLive.Index, as: Artifacts
  alias Tune.UI.DashboardLive, as: Dashboard
  alias Tune.UI.RunLive.Show, as: RunReport
  alias Tune.UI.Runner
  alias Tune.UI.SettingsLive, as: Diagnostics
  alias Tune.UI.Store
  alias Tune.UI.StudyLive

  defmodule OfflineRecipe do
    @behaviour Tune.UI.Recipe

    def id, do: "offline"
    def label, do: "Offline evaluation"
    def description, do: "Test workbench execution with local data."
    def default_config, do: %{}
    def preview_input(_study), do: {:ok, 1}

    def build(%{config: %{"transport" => stub}, data: data}) do
      {:ok, predictor} =
        Tune.Predictor.new(
          signature: [inputs: [question: Zoi.string()], outputs: [answer: Zoi.string()]]
        )

      pipeline =
        predictor
        |> Tune.new(
          model: [
            model: Transport.model(),
            adapter: Tune.Adapter.Chat,
            request_options: Transport.request_options(stub)
          ]
        )
        |> Tune.data(data)
        |> Tune.score(:accuracy, fn row, output -> if row.expected == output, do: 1, else: 0 end,
          argument: :output
        )

      {:ok, pipeline}
    end

    def build(%{config: %{"owner" => owner}, data: data}) do
      pipeline =
        Tune.new(:blocked,
          run: fn _, _ ->
            send(owner, {:row_started, self()})
            Process.sleep(:infinity)
          end
        )
        |> Tune.data(data)
        |> Tune.score(:value, & &1)

      {:ok, pipeline}
    end

    def build(%{config: config, data: data}) do
      runner =
        if config["failed_rows"],
          do: fn _, _ -> {:error, :unavailable} end,
          else: fn target, row -> target.weight * row end

      pipeline =
        Tune.new(%{weight: Map.get(config, "weight", 1)}, run: runner)
        |> Tune.data(data)
        |> Tune.score(:value, & &1)
        |> Tune.vary(weight: 1..3)
        |> Tune.search(:grid)

      {:ok, pipeline}
    end
  end

  setup do
    start_supervised!(Store)
    start_supervised!({Task.Supervisor, name: Tune.UI.TaskSupervisor})

    config = Application.fetch_env(:tune, Tune.UI)
    Application.put_env(:tune, Tune.UI, recipes: [OfflineRecipe])

    on_exit(fn ->
      case config do
        {:ok, value} -> Application.put_env(:tune, Tune.UI, value)
        :error -> Application.delete_env(:tune, Tune.UI)
      end
    end)
  end

  test "creates a study through the form, edits its settings, and previews a saved data row" do
    assert render(StudyLive.Index, mount(StudyLive.Index)) =~ "Create a study to configure"
    new = mount(StudyLive.New)
    assert render(StudyLive.New, new) =~ "Create study"

    params = %{
      "name" => "Shipping classifier",
      "recipe" => "structured_prompt",
      "limits" => ~s({"cases":2}),
      "strategy_options" => ~s({"k":2})
    }

    assert {:noreply, rejected} =
             submit(StudyLive.New, new, "study", %{params | "limits" => "{"})

    assert rejected.assigns.error
    assert render(StudyLive.New, rejected) =~ "Shipping classifier"
    assert Store.list_studies() == []

    assert {:noreply, %{redirected: {:live, :redirect, %{to: "/studies/" <> id}}}} =
             submit(StudyLive.New, new, "study", params)

    assert Store.get_study(id).config["limits"] == %{cases: 2}
    assert render(StudyLive.Index, mount(StudyLive.Index)) =~ "/studies/#{id}"
    assert render(StudyLive.Show, mount(StudyLive.Show, id)) =~ "Shipping classifier"

    empty_preview = mount(StudyLive.Preview, id)
    assert render(StudyLive.Preview, empty_preview) =~ "add at least one data row"

    settings = mount(StudyLive.Settings, id)

    assert {:noreply, rejected} =
             submit(StudyLive.Settings, settings, "study", %{
               "name" => "Bad update",
               "limits" => ~s({"concurrency":0})
             })

    assert render(StudyLive.Settings, rejected) =~ "concurrency"
    assert Store.get_study(id).name == "Shipping classifier"

    assert {:noreply, updated} =
             submit(StudyLive.Settings, settings, "study", %{
               "name" => "Shipping count",
               "instructions" => "Count the packages.",
               "output_type" => "integer",
               "adapter" => "json",
               "limits" => ~s({"row_calls":1}),
               "strategy_options" => ~s({"k":1})
             })

    assert updated.assigns.error == nil
    assert render(StudyLive.Settings, updated) =~ "Shipping count"
    assert Store.get_study(id).config["limits"] == %{row_calls: 1}

    editor = mount(StudyLive.Data, id)

    assert {:noreply, rejected} =
             submit(StudyLive.Data, editor, "data", %{"train" => ~s([{"labels":{}}])})

    assert render(StudyLive.Data, rejected) =~ "train row 1"
    assert Store.get_study(id).data.train == []

    assert {:noreply, editor} =
             submit(StudyLive.Data, editor, "data", %{
               "train" => ~s([{"inputs":{"input":"Three packages"},"labels":{"output":3}}])
             })

    assert render(StudyLive.Data, editor) =~ "Three packages"
    preview = render(StudyLive.Preview, mount(StudyLive.Preview, id))
    assert preview =~ "Rendered messages"
    assert preview =~ "Count the packages."
    assert preview =~ "Three packages"
    assert preview =~ "Equivalent pipeline"
  end

  test "missing studies and runs redirect to their lists" do
    for view <- [
          StudyLive.Show,
          StudyLive.Settings,
          StudyLive.Data,
          StudyLive.Preview,
          StudyLive.Run
        ] do
      assert %{redirected: {:live, :redirect, %{to: "/studies"}}} = mount(view, "missing-study")
    end

    assert %{redirected: {:live, :redirect, %{to: "/"}}} = mount(RunReport, "missing-run")

    assert {:error, %Tune.Error.Invalid.Definition{message: "study was not found"}} =
             Store.update_study("missing-study", %{name: "New name"})

    conn =
      :get
      |> Plug.Test.conn("/runs/missing-run/artifact")
      |> Plug.Test.init_test_session(%{})
      |> Tune.UI.Router.call(Tune.UI.Router.init([]))

    assert conn.status == 404
    assert conn.resp_body == "artifact not found"
  end

  test "dashboard loads the example and shows individual scores from completed runs" do
    before_runs = mount(Dashboard)
    assert render(Dashboard, before_runs) =~ "Runs will appear here"
    assert render(Artifacts, mount(Artifacts)) =~ "A completed tuning run will appear here"

    assert {:noreply, %{redirected: {:live, :redirect, %{to: "/studies/" <> path}}}} =
             Dashboard.handle_event("load-example", %{}, before_runs)

    assert [example_id, "preview"] = String.split(path, "/")
    assert preview = render(StudyLive.Preview, mount(StudyLive.Preview, example_id))
    assert preview =~ "Rendered messages"

    study = offline_study(%{}, %{test: [2], validation: [2]})
    assert {:ok, evaluated} = Runner.start(study, :evaluate)
    assert finished(evaluated.id).result.selected_score == 2

    assert {:ok, tuned} = Runner.start(study, :tune)
    assert %Tune.Artifact{} = finished(tuned.id).artifact

    dashboard = mount(Dashboard)
    html = render(Dashboard, dashboard)
    assert html =~ "Score 2"
    assert html =~ "Score 6.0"
    refute html =~ "Score trend"
    assert html =~ "/runs/#{evaluated.id}"
    assert render(Artifacts, mount(Artifacts)) =~ "/runs/#{tuned.id}/artifact"
    refute render(Artifacts, mount(Artifacts)) =~ "/runs/#{evaluated.id}/artifact"

    assert {:ok, changed} = Store.update_study(study.id, %{data: %{test: [1]}})
    assert {:ok, run} = Runner.start(changed, :evaluate)
    assert finished(run.id).status == :completed
    assert render(Dashboard, mount(Dashboard)) =~ "Score 1"
  end

  test "run preflight reports missing splits and rejects submission" do
    {:ok, study} =
      Store.create_study(%{
        name: "Prompt search",
        recipe: "structured_prompt",
        config: %{"strategy" => "copro", "strategy_options" => %{}}
      })

    page = mount(StudyLive.Run, study.id)
    html = render(StudyLive.Run, page)
    assert html =~ "Add training data before tuning."
    assert html =~ "Add test, validation, or training data before evaluation."

    assert {:noreply, page} =
             StudyLive.Run.handle_event("start", %{"mode" => "evaluate"}, page)

    assert render(StudyLive.Run, page) =~ "evaluation data is required"

    assert {:noreply, page} = StudyLive.Run.handle_event("compare", %{"split" => ""}, page)
    assert render(StudyLive.Run, page) =~ "choose a dataset split"
    assert Store.list_runs() == []

    assert {:ok, _study} =
             Store.update_study(study.id, %{data: %{train: [%{inputs: %{"input" => "row"}}]}})

    assert render(StudyLive.Run, mount(StudyLive.Run, study.id)) =~
             "Add validation data for candidate search."
  end

  test "cancels a running evaluation and refreshes its retained report" do
    study = offline_study(%{"owner" => self()}, %{test: [1]})

    assert {:noreply, %{redirected: {:live, :redirect, %{to: "/runs/" <> run_id}}}} =
             StudyLive.Run.handle_event(
               "start",
               %{"mode" => "evaluate"},
               mount(StudyLive.Run, study.id)
             )

    assert_receive {:row_started, worker}, 1_000
    report = mount(RunReport, run_id)
    assert render(RunReport, report) =~ ~s(phx-click="cancel")
    assert {:noreply, report} = RunReport.handle_event("cancel", %{}, report)
    assert report.assigns.run.cancel_requested?
    assert %{status: :cancelled, result: %{stop_reason: :cancelled}} = finished(run_id)
    refute Process.alive?(worker)

    assert {:noreply, refreshed} = RunReport.handle_info(:refresh, report)
    assert render(RunReport, refreshed) =~ "cancelled"
    refute render(RunReport, refreshed) =~ ~s(phx-click="cancel")
  end

  test "failed searches keep candidate evidence and cannot be used for comparison" do
    study = offline_study(%{"failed_rows" => true}, %{validation: [1], test: [2]})
    assert {:ok, run} = Runner.start(study, :tune)

    assert %{
             status: :failed,
             artifact: nil,
             error: %Tune.Error.Optimization.Failed{},
             result: %{complete?: false, history: history}
           } = finished(run.id)

    assert length(history) == 3

    for candidate <- history do
      assert [%{status: :error, error: :unavailable}] = candidate.evaluation.observations
    end

    report = mount(RunReport, run.id)
    assert render(RunReport, report) =~ "no candidate completed an eligible evaluation"
    refute render(RunReport, report) =~ "Download JSON"

    assert {:noreply, report} = RunReport.handle_event("compare", %{"split" => "test"}, report)
    assert render(RunReport, report) =~ "complete a search before comparison"
    assert [%{id: id}] = Store.list_runs()
    assert id == run.id
    assert render(Dashboard, mount(Dashboard)) =~ "badge-error"
  end

  test "diagnostics shows models that responded to a scripted evaluation" do
    stub = Transport.script([Transport.chat(answer: "Paris")])

    study =
      offline_study(%{"transport" => stub}, %{
        test: [%{input: %{question: "Where is the Eiffel Tower?"}, expected: %{answer: "Paris"}}]
      })

    assert {:ok, run} = Runner.start(study, :evaluate)
    assert %{status: :completed, result: %{selected_score: 1.0}} = finished(run.id)
    assert [_] = Transport.requests(stub)
    assert render(RunReport, mount(RunReport, run.id)) =~ "15 tokens"

    diagnostics = mount(Diagnostics)
    html = render(Diagnostics, diagnostics)
    assert diagnostics.assigns.verified_count == 1
    assert html =~ "Verified by completed run"
    assert html =~ "openai:gpt-4-turbo"
    assert html =~ "ReqLLM diagnostics"
    refute html =~ "test-secret-key"

    assert {:noreply, refreshed} = Diagnostics.handle_event("scan", %{}, diagnostics)
    assert refreshed.assigns.verified_count == 1
    assert refreshed.assigns.scanned_at >= diagnostics.assigns.scanned_at
    assert Transport.requests(stub) == []
  end

  test "the launcher rejects unsupported arguments before starting the workbench" do
    assert_raise Mix.Error, ~r/usage: mix tune.ui/, fn ->
      Mix.Tasks.Tune.Ui.run(["--unknown", "argument"])
    end
  end

  defp offline_study(config, data) do
    {:ok, study} =
      Store.create_study(%{name: "Offline study", recipe: "offline", config: config, data: data})

    study
  end

  defp mount(view, id \\ nil) do
    params = if id, do: %{"id" => id}, else: %{}
    assert {:ok, socket} = view.mount(params, %{}, %Phoenix.LiveView.Socket{})
    socket
  end

  defp submit(view, socket, form, params),
    do: view.handle_event("save", %{form => params}, socket)

  defp render(view, socket) do
    socket.assigns |> view.render() |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
  end

  defp finished(id, attempts \\ 200)
  defp finished(id, 0), do: flunk("run did not finish: #{inspect(Store.get_run(id))}")

  defp finished(id, remaining) do
    case Store.get_run(id) do
      %{status: status} = run when status in [:completed, :failed, :cancelled] ->
        run

      _ ->
        Process.sleep(10)
        finished(id, remaining - 1)
    end
  end
end
