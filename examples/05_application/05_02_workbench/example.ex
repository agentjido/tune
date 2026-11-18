defmodule Tune.Examples.Workbench do
  @moduledoc "Run and compare studies through the local workbench without a network listener."

  alias Phoenix.LiveView.Socket
  alias Tune.UI.{RunLive, Runner, Store, StudyLive}

  def run do
    previous = Application.fetch_env(:tune, Tune.UI)

    {:ok, supervisor} =
      Supervisor.start_link([Store, {Task.Supervisor, name: Tune.UI.TaskSupervisor}],
        strategy: :one_for_one
      )

    Application.put_env(:tune, Tune.UI,
      recipes: [Tune.Examples.Workbench.SavedRecipe, Tune.Examples.Workbench.RouterRecipe]
    )

    try do
      saved = saved_answers()
      {search, comparison, missing_split, rendered} = tune_and_compare()
      download = download(search.id)

      %{
        saved: saved,
        search: search,
        comparison: comparison,
        missing_split: missing_split,
        download: download,
        rendered: rendered
      }
    after
      Supervisor.stop(supervisor)
      restore_config(previous)
    end
  end

  defp saved_answers do
    {:ok, study} = Store.create_study(%{name: "Saved ticket routes", recipe: "example_saved"})
    {:ok, socket} = StudyLive.Data.mount(%{"id" => study.id}, %{}, %Socket{})

    rows = [%{id: "card", input: "Charged twice", output: "billing", expected: "billing"}]

    {:noreply, socket} =
      StudyLive.Data.handle_event("save", %{"data" => %{"test" => JSON.encode!(rows)}}, socket)

    true = is_nil(socket.assigns.error)
    {:ok, socket} = StudyLive.Run.mount(%{"id" => study.id}, %{}, %Socket{})

    {:noreply, %{redirected: {:live, :redirect, %{to: "/runs/" <> id}}}} =
      StudyLive.Run.handle_event("start", %{"mode" => "evaluate"}, socket)

    await(id)
  end

  defp tune_and_compare do
    training = %{
      "id" => "train1",
      "input" => %{"ticket" => "Refund charged twice"},
      "expected" => %{"label" => "billing"}
    }

    {:ok, study} =
      Store.create_study(%{
        name: "Support router",
        recipe: "example_router",
        data: %{train: [training, Map.put(training, "id", "duplicate")]}
      })

    {:ok, search} = Runner.start(study, :tune)
    search = await(search.id)
    {:error, missing_split} = Runner.start(study, :compare)

    holdout = %{
      id: "holdout1",
      input: %{ticket: "Credit card fee"},
      expected: %{label: "billing"}
    }

    {:ok, _study} = Store.update_study(study.id, %{data: %{test: [holdout]}})
    {:ok, socket} = RunLive.Show.mount(%{"id" => search.id}, %{}, %Socket{})

    {:noreply, %{redirected: {:live, :redirect, %{to: "/runs/" <> id}}}} =
      RunLive.Show.handle_event("compare", %{"split" => "test"}, socket)

    comparison = await(id)

    {:ok, _edited} =
      Store.update_study(study.id, %{name: "Edited router", data: %{test: []}})

    {:ok, socket} = RunLive.Show.mount(%{"id" => id}, %{}, %Socket{})

    rendered =
      socket.assigns
      |> RunLive.Show.render()
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()

    {search, comparison, missing_split, rendered}
  end

  defp await(id) do
    for pid <- Task.Supervisor.children(Tune.UI.TaskSupervisor) do
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        2_000 -> raise "workbench run timed out"
      end
    end

    %{status: :completed} = Store.get_run(id)
  end

  defp download(id) do
    :get
    |> Plug.Test.conn("/runs/#{id}/artifact")
    |> Plug.Test.init_test_session(%{})
    |> Tune.UI.Router.call(Tune.UI.Router.init([]))
  end

  defp restore_config({:ok, value}), do: Application.put_env(:tune, Tune.UI, value)
  defp restore_config(:error), do: Application.delete_env(:tune, Tune.UI)
end

defmodule Tune.Examples.Workbench.SavedRecipe do
  @moduledoc false
  @behaviour Tune.UI.Recipe

  @impl true
  def id, do: "example_saved"
  @impl true
  def label, do: "Saved ticket routes"
  @impl true
  def description, do: "Check saved ticket routes for exact matches."
  @impl true
  def default_config, do: %{}
  @impl true
  def preview_input(_), do: {:error, :no_prompt}

  @impl true
  def build(study) do
    pipeline =
      Tune.replay(Map.fetch!(study.data, :test))
      |> Tune.score(:route, fn row, output -> if row.expected == output, do: 1, else: 0 end)

    {:ok, pipeline}
  end
end

defmodule Tune.Examples.Workbench.RouterRecipe do
  @moduledoc false
  @behaviour Tune.UI.Recipe

  alias Tune.Examples.Support.{Offline, Tickets}
  alias Tune.Examples.Support.Transport

  @impl true
  def id, do: "example_router"
  @impl true
  def label, do: "Ticket router"
  @impl true
  def description, do: "Learn routing demonstrations from support tickets."
  @impl true
  def default_config, do: %{}
  @impl true
  def preview_input(_), do: {:ok, %{ticket: "Credit card fee"}}

  @impl true
  def build(study) do
    stub =
      Transport.respond_with(fn body ->
        demos? = Enum.any?(body["messages"], &(&1["role"] == "assistant"))
        Transport.chat(label: if(demos?, do: "billing", else: "general"))
      end)

    pipeline =
      Tune.new(Tickets.classifier(), model: Offline.model(stub))
      |> Tune.data(study.data)
      |> Tune.score(:route, &Tickets.exact/2, argument: :output)
      |> Tune.search(:labeled_few_shot)
      |> Tune.limit(model_calls: 5, seed: 2)

    {:ok, pipeline}
  end
end
