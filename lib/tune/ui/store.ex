defmodule Tune.UI.Store do
  @moduledoc false
  use GenServer

  alias Tune.UI.Run
  alias Tune.UI.Study

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec list_studies() :: [Study.t()]
  def list_studies, do: GenServer.call(__MODULE__, :list_studies)

  @spec get_study(String.t()) :: Study.t() | nil
  def get_study(id), do: GenServer.call(__MODULE__, {:get_study, id})

  @spec create_study(map()) :: {:ok, Study.t()} | {:error, Exception.t()}
  def create_study(attrs), do: GenServer.call(__MODULE__, {:create_study, attrs})

  @spec update_study(String.t(), map()) :: {:ok, Study.t()} | {:error, Exception.t()}
  def update_study(id, attrs), do: GenServer.call(__MODULE__, {:update_study, id, attrs})

  @spec list_runs() :: [Run.t()]
  def list_runs, do: GenServer.call(__MODULE__, :list_runs)

  @spec get_run(String.t()) :: Run.t() | nil
  def get_run(id), do: GenServer.call(__MODULE__, {:get_run, id})

  @spec create_run(String.t(), :evaluate | :tune) :: {:ok, Run.t()}
  def create_run(study_id, mode), do: GenServer.call(__MODULE__, {:create_run, study_id, mode})

  @spec update_run(String.t(), map()) :: :ok
  def update_run(id, attrs), do: GenServer.call(__MODULE__, {:update_run, id, attrs})

  @impl true
  def init(_opts), do: {:ok, %{studies: %{}, runs: %{}}}

  @impl true
  def handle_call(:list_studies, _from, state) do
    {:reply, sorted(state.studies), state}
  end

  def handle_call({:get_study, id}, _from, state),
    do: {:reply, Map.get(state.studies, id), state}

  def handle_call({:create_study, attrs}, _from, state) do
    case Study.new(attrs) do
      {:ok, study} ->
        {:reply, {:ok, study}, put_in(state.studies[study.id], study)}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:update_study, id, attrs}, _from, state) do
    case Map.fetch(state.studies, id) do
      {:ok, study} ->
        case Study.update(study, attrs) do
          {:ok, updated} ->
            {:reply, {:ok, updated}, put_in(state.studies[id], updated)}

          error ->
            {:reply, error, state}
        end

      :error ->
        {:reply, not_found("study"), state}
    end
  end

  def handle_call(:list_runs, _from, state), do: {:reply, sorted(state.runs), state}

  def handle_call({:get_run, id}, _from, state),
    do: {:reply, Map.get(state.runs, id), state}

  def handle_call({:create_run, study_id, mode}, _from, state) do
    now = DateTime.utc_now()

    run = %Run{
      id: id("run"),
      study_id: study_id,
      mode: mode,
      status: :queued,
      inserted_at: now
    }

    {:reply, {:ok, run}, put_in(state.runs[run.id], run)}
  end

  def handle_call({:update_run, id, attrs}, _from, state) do
    updated = state.runs |> Map.fetch!(id) |> then(&struct(&1, attrs))
    {:reply, :ok, put_in(state.runs[id], updated)}
  end

  defp sorted(values) do
    values
    |> Map.values()
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  end

  defp id(prefix),
    do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

  defp not_found(kind),
    do: {:error, Tune.Error.Invalid.Definition.exception(message: "#{kind} was not found")}
end
