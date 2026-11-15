defmodule Tune.UI.Runner do
  @moduledoc false

  alias Tune.UI.Registry
  alias Tune.UI.Store
  alias Tune.UI.Study

  @spec start(Study.t(), :evaluate | :tune) :: {:ok, Tune.UI.Run.t()} | {:error, term()}
  def start(%Study{} = study, mode) when mode in [:evaluate, :tune] do
    with {:ok, run} <- Store.create_run(study.id, mode),
         {:ok, _pid} <-
           Task.Supervisor.start_child(Tune.UI.TaskSupervisor, fn ->
             execute(run.id, study, mode)
           end) do
      {:ok, run}
    end
  end

  defp execute(run_id, study, mode) do
    Store.update_run(run_id, %{status: :running, started_at: DateTime.utc_now()})

    outcome =
      with {:ok, recipe} <- Registry.fetch(study.recipe),
           {:ok, pipeline} <- recipe.build(study) do
        terminal(pipeline, study, mode)
      end

    finish(run_id, outcome)
  rescue
    error -> finish(run_id, {:error, error})
  catch
    kind, reason -> finish(run_id, {:error, {kind, reason}})
  end

  defp terminal(pipeline, _study, :tune) do
    with {:ok, result} <- Tune.tune(pipeline),
         {:ok, artifact} <- Tune.dump(result) do
      {:ok, result, artifact}
    end
  end

  defp terminal(pipeline, study, :evaluate) do
    role = Enum.find([:test, :validation, :train], &(Map.get(study.data, &1, []) != []))

    if role,
      do: Tune.evaluate(pipeline, role),
      else:
        {:error, Tune.Error.Invalid.Definition.exception(message: "evaluation data is required")}
  end

  defp finish(run_id, {:ok, result, artifact}) do
    Store.update_run(run_id, %{
      status: :completed,
      result: result,
      artifact: artifact,
      finished_at: DateTime.utc_now()
    })
  end

  defp finish(run_id, {:ok, result}) do
    Store.update_run(run_id, %{
      status: :completed,
      result: result,
      finished_at: DateTime.utc_now()
    })
  end

  defp finish(run_id, {:error, error}) do
    Store.update_run(run_id, %{
      status: :failed,
      error: error,
      finished_at: DateTime.utc_now()
    })
  end
end
