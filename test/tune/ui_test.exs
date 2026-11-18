defmodule Tune.UITest do
  use ExUnit.Case, async: false

  alias Tune.UI.Registry
  alias Tune.UI.Store

  setup do
    start_supervised!(Store)
    start_supervised!({Task.Supervisor, name: Tune.UI.TaskSupervisor})
    :ok
  end

  defmodule NumberRecipe do
    @behaviour Tune.UI.Recipe

    def id, do: "numbers"
    def label, do: "Numbers"
    def description, do: "A local arithmetic benchmark"
    def default_config, do: %{}
    def preview_input(_study), do: {:ok, 1}

    def build(study) do
      config =
        [
          model: study.config["model"],
          adapter: Tune.Adapter.Chat,
          request_options: [api_key: "fixture-key", temperature: study.config["temperature"]]
        ]

      pipeline =
        Tune.new(%{value: 0}, model: config, run: fn target, factor -> target.value * factor end)
        |> Tune.data(study.data)
        |> Tune.vary(value: 0..1)
        |> Tune.score(:value, & &1)
        |> Tune.search(:genetic, initial_population: [%{value: 0}, %{value: 1}], generations: 0)
        |> Tune.limit(evaluations: 2)

      {:ok, pipeline}
    end
  end

  test "the optional router exposes the workbench routes" do
    routes =
      Tune.UI.Router.__routes__()
      |> Enum.map(&{&1.verb, &1.path})
      |> MapSet.new()

    expected = [
      {:get, "/"},
      {:get, "/studies"},
      {:get, "/studies/new"},
      {:get, "/studies/:id"},
      {:get, "/studies/:id/settings"},
      {:get, "/studies/:id/data"},
      {:get, "/studies/:id/preview"},
      {:get, "/studies/:id/run"},
      {:get, "/runs/:id"},
      {:get, "/artifacts"},
      {:get, "/settings"},
      {:get, "/runs/:id/artifact"}
    ]

    assert MapSet.subset?(MapSet.new(expected), routes)
  end

  test "the store creates and updates studies without persistence" do
    assert {:ok, study} =
             Store.create_study(%{
               name: "Grounded QA",
               recipe: "structured_prompt",
               config: %{"model" => "test:model"},
               data: %{train: []}
             })

    assert Store.get_study(study.id) == study

    assert {:ok, updated} =
             Store.update_study(study.id, %{data: %{train: [%{"inputs" => %{}, "labels" => %{}}]}})

    assert updated.id == study.id
    assert updated.inserted_at == study.inserted_at
    assert length(updated.data.train) == 1
  end

  test "the registry resolves only declared recipe IDs" do
    assert {:ok, Tune.UI.Recipes.StructuredPrompt} = Registry.fetch("structured_prompt")
    assert {:error, %Tune.Error.Invalid.Definition{}} = Registry.fetch("Elixir.System")
  end

  test "the store validates saved rows and recipe settings before accepting edits" do
    assert {:ok, study} =
             Store.create_study(%{
               name: "Saved answers",
               recipe: "saved_responses",
               config: %{"limits" => %{"concurrency" => 2}},
               data: %{"test" => [%{"id" => 1, "input" => nil, "output" => nil}]}
             })

    assert [%Tune.Replay{id: "1", input: nil, output: nil}] = study.data.test
    assert study.config["limits"] == %{concurrency: 2, model_calls: 100}
    assert {:ok, _pipeline} = Tune.UI.Recipes.SavedResponses.build(study)

    assert {:error, %Tune.Error.Invalid.Definition{message: message}} =
             Store.update_study(study.id, %{data: %{test: [%{"input" => "missing answer"}]}})

    assert message =~ "test row 1"
    assert message =~ "output"

    assert {:error, %Tune.Error.Invalid.Definition{message: message}} =
             Store.update_study(study.id, %{config: %{"limits" => %{"concurrency" => 0}}})

    assert message =~ "concurrency"
    assert Store.get_study(study.id) == study
  end

  test "the saved-answer editor saves rows that the run page can evaluate" do
    assert {:ok, study} =
             Store.create_study(%{
               name: "Saved answers",
               recipe: "saved_responses",
               config: %{"limits" => %{"model_calls" => 0}}
             })

    editor = Tune.UI.StudyLive.Data
    runner = Tune.UI.StudyLive.Run
    params = %{"test" => ~s([{"id":"saved","input":"question","output":"answer"}])}

    assert {:ok, socket} = editor.mount(%{"id" => study.id}, %{}, %Phoenix.LiveView.Socket{})
    assert {:noreply, socket} = editor.handle_event("save", %{"data" => params}, socket)
    assert socket.assigns.error == nil
    assert [%Tune.Replay{id: "saved", output: "answer"}] = Store.get_study(study.id).data.test

    assert {:ok, socket} = runner.mount(%{"id" => study.id}, %{}, %Phoenix.LiveView.Socket{})

    assert {:noreply, %{redirected: {:live, :redirect, %{to: "/runs/" <> run_id}}}} =
             runner.handle_event("start", %{"mode" => "evaluate"}, socket)

    assert %{status: :completed, result: result, evidence: evidence} = finished_run(run_id)
    assert [%{id: "saved", status: :skipped}] = result.observations
    assert result.calls == %{}
    assert %{source: %{rows: 1}, effective: %{rows: 1}} = evidence.datasets.test
  end

  test "a program search records selected source rows and deduplicated cases" do
    row = %{"inputs" => %{"input" => "hello"}, "labels" => %{"output" => "greeting"}}
    excluded = put_in(row["inputs"]["input"], "goodbye")

    assert {:ok, study} =
             Store.create_study(%{
               name: "Greetings",
               recipe: "structured_prompt",
               config: %{"limits" => %{"cases" => 2}},
               data: %{train: [row, row, excluded]}
             })

    assert {:ok, run} = Tune.UI.Runner.start(study, :tune)
    assert %{status: :completed, result: result, evidence: evidence} = finished_run(run.id)

    assert %{
             source: %{rows: 2, fingerprint: source},
             effective: %{rows: 1, fingerprint: effective}
           } = evidence.datasets.train

    refute source == effective
    assert result.metadata.datasets.train == 1
    assert result.metadata.notes.train_duplicates_removed == 1
    assert [%{inputs: %{"input" => "hello"}}] = result.value.demos
  end

  test "known model suggestions include models used by studies" do
    assert {:ok, _study} =
             Store.create_study(%{
               name: "Local model",
               recipe: "structured_prompt",
               config: %{"model" => "lmstudio:local-model"},
               data: %{}
             })

    assert "lmstudio:local-model" in Tune.UI.Components.known_models()
  end

  test "the grounded QA example is complete and previewable offline" do
    attrs = Tune.UI.Examples.grounded_qa()

    assert length(attrs.data.train) == 2
    assert length(attrs.data.validation) == 1
    assert length(attrs.data.test) == 1
    assert {:ok, study} = Store.create_study(attrs)
    assert {:ok, pipeline} = Tune.UI.Recipes.StructuredPrompt.build(study)
    assert {:ok, input} = Tune.UI.Recipes.StructuredPrompt.preview_input(study)
    assert {:ok, prepared} = Tune.preview(pipeline, input)
    assert prepared.inputs == input
  end

  test "the built-in recipe builds a lazy pipeline and previews offline" do
    config = Tune.UI.Recipes.StructuredPrompt.default_config()

    assert {:ok, study} =
             Store.create_study(%{
               name: "Classifier",
               recipe: "structured_prompt",
               config: config,
               data: %{
                 train: [
                   %{
                     "inputs" => %{"input" => "hello"},
                     "labels" => %{"output" => "greeting"}
                   }
                 ]
               }
             })

    recipe = Tune.UI.Recipes.StructuredPrompt

    assert {:ok, %Tune{} = pipeline} = recipe.build(study)
    assert pipeline.strategy == {:labeled_few_shot, [k: 4, sample: false]}
    assert {:ok, %{"input" => "hello"} = input} = recipe.preview_input(study)
    assert {:ok, prepared} = Tune.preview(pipeline, input)
    assert prepared.inputs == %{"input" => "hello"}
  end

  test "the workbench requires an explicit split and keeps run evidence after study edits" do
    previous = Application.get_env(:tune, Tune.UI, [])
    Application.put_env(:tune, Tune.UI, Keyword.put(previous, :recipes, [NumberRecipe]))
    on_exit(fn -> Application.put_env(:tune, Tune.UI, previous) end)

    assert {:ok, study} =
             Store.create_study(%{
               name: "Arithmetic",
               recipe: "numbers",
               config: %{"model" => "openai:gpt-4o-mini", "temperature" => 0.2},
               data: %{validation: [1]}
             })

    assert {:ok, run} = Tune.UI.Runner.start(study, :tune)

    assert %{
             status: :completed,
             artifact: %Tune.Artifact{} = artifact,
             progress: %{generations: 1}
           } =
             finished_run(run.id)

    download =
      :get
      |> Plug.Test.conn("/runs/#{run.id}/artifact")
      |> Plug.Test.init_test_session(%{})
      |> Tune.UI.Router.call(Tune.UI.Router.init([]))

    assert download.status == 200

    assert Plug.Conn.get_resp_header(download, "content-disposition") == [
             ~s(attachment; filename="#{run.id}.json")
           ]

    assert {:ok, ^artifact} = Tune.Artifact.decode(download.resp_body)

    run_view = render_run(run.id)
    assert run_view =~ "Compare with baseline"
    assert run_view =~ "No test rows"
    assert run_view =~ "Choose a split"
    refute run_view =~ ~s(value="test")

    assert {:error, %Tune.Error.Invalid.Definition{message: message}} =
             Tune.UI.Runner.start(study, :compare)

    assert message =~ "choose a dataset split"

    assert {:error, %Tune.Error.Invalid.Definition{}} =
             Tune.UI.Runner.start(study, :compare, split: :test)

    assert {:ok, study} =
             Store.update_study(study.id, %{data: %{validation: [1], test: [10, -20]}})

    view = Tune.UI.RunLive.Show
    assert {:ok, socket} = view.mount(%{"id" => run.id}, %{}, %Phoenix.LiveView.Socket{})

    assert {:noreply, %{redirected: {:live, :redirect, %{to: "/runs/" <> comparison_id}}}} =
             view.handle_event("compare", %{"split" => "test"}, socket)

    assert %{status: :completed, result: result, progress: %{rows: 4}, evidence: evidence} =
             finished_run(comparison_id)

    assert result.baseline.selected_score == 0
    assert result.challenger.selected_score == -5
    assert evidence.splits == [:test]

    assert %{
             source: %{fingerprint: fingerprint, rows: 2},
             effective: %{fingerprint: effective, rows: 2}
           } = evidence.datasets.test

    refute fingerprint == effective
    assert [%{name: :value, direction: :maximize}] = evidence.scores
    assert evidence.models["target"]["model"] == "openai:gpt-4o-mini"
    assert evidence.models["target"]["generation_options"] == %{temperature: 0.2}

    assert {:ok, _edited} =
             Store.update_study(study.id, %{
               name: "New name",
               config: %{"model" => "openai:gpt-4.1"},
               data: %{test: [99]}
             })

    assert Store.get_run(comparison_id).evidence == evidence
    html = render_run(comparison_id)
    assert html =~ "Arithmetic"
    assert html =~ fingerprint
    assert html =~ effective
    assert html =~ "Source rows"
    assert html =~ "Effective cases"
    assert html =~ "openai:gpt-4o-mini"
    assert html =~ "regressed"
    refute html =~ "New name"
    refute html =~ "openai:gpt-4.1"
    refute html =~ "fixture-key"
  end

  defp render_run(id) do
    view = Tune.UI.RunLive.Show
    assert {:ok, socket} = view.mount(%{"id" => id}, %{}, %Phoenix.LiveView.Socket{})
    socket.assigns |> view.render() |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
  end

  defp finished_run(id, attempts \\ 100)
  defp finished_run(id, 0), do: Store.get_run(id)

  defp finished_run(id, attempts) do
    case Store.get_run(id) do
      %{status: status} = run when status in [:completed, :failed, :cancelled] ->
        run

      _run ->
        Process.sleep(10)
        finished_run(id, attempts - 1)
    end
  end
end
