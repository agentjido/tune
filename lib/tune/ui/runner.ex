defmodule Tune.UI.Runner do
  @moduledoc false

  alias Tune.UI.Evidence
  alias Tune.UI.Registry
  alias Tune.UI.Store
  alias Tune.UI.Study

  @splits [:test, :validation, :train]

  @spec start(Study.t(), :evaluate | :tune | :compare, keyword()) ::
          {:ok, Tune.UI.Run.t()} | {:error, term()}
  def start(%Study{} = study, mode, opts \\ []) when mode in [:evaluate, :tune, :compare] do
    with {:ok, prepared, winner, split, attrs} <- prepare(study, mode, opts),
         {:ok, run} <- Store.create_run(study.id, mode, attrs) do
      case Task.Supervisor.start_child(Tune.UI.TaskSupervisor, fn ->
             execute(run.id, prepared, mode, winner, split)
           end) do
        {:ok, _pid} ->
          {:ok, run}

        {:error, _reason} = error ->
          finish(run.id, error)
          error
      end
    end
  end

  def available_splits(%Study{} = study) do
    splits = if study.recipe == "saved_responses", do: [:test], else: @splits
    Enum.filter(splits, &(Map.get(study.data, &1, []) != []))
  end

  def latest_search(study_id) do
    Enum.find(Store.list_runs(), &completed_search?(&1, study_id))
  end

  @spec cancel(String.t()) :: :ok
  def cancel(id), do: Store.update_run(id, %{cancel_requested?: true})

  defp prepare(study, :compare, opts) do
    with {:ok, split} <- comparison_split(study, opts[:split]),
         {:ok, source} <- search_run(study.id, opts[:from]) do
      original = %{source.study_snapshot | data: study.data}
      {:ok, original, source.result, split, %{source_run_id: source.id}}
    end
  end

  defp prepare(study, :evaluate, _opts) do
    case available_splits(study) do
      [split | _] -> {:ok, study, nil, split, %{}}
      [] -> invalid("evaluation data is required")
    end
  end

  defp prepare(study, :tune, _opts) do
    {:ok, study, nil, nil, %{study_snapshot: %{study | data: %{}}}}
  end

  defp comparison_split(study, requested) do
    case Enum.find(available_splits(study), &(requested in [&1, to_string(&1)])) do
      nil -> invalid("choose a dataset split with rows for comparison")
      split -> {:ok, split}
    end
  end

  defp search_run(study_id, run_id) do
    run = if run_id, do: Store.get_run(run_id), else: latest_search(study_id)

    if completed_search?(run, study_id),
      do: {:ok, run},
      else: invalid("complete a search before comparison")
  end

  defp completed_search?(
         %{study_id: id, mode: :tune, status: :completed, result: %Tune.Result{}},
         id
       ),
       do: true

  defp completed_search?(_run, _id), do: false

  defp invalid(message), do: {:error, Tune.Error.Invalid.Definition.exception(message: message)}

  defp execute(run_id, study, mode, winner, split) do
    Store.update_run(run_id, %{status: :running, started_at: DateTime.utc_now()})

    outcome =
      with {:ok, recipe} <- Registry.fetch(study.recipe),
           {:ok, pipeline} <- recipe.build(study) do
        splits = run_splits(pipeline, mode, split)
        pipeline = Evidence.capture(pipeline, study, splits, run_id)
        previous = pipeline.on_progress
        previous_cancel = pipeline.cancel

        pipeline = %{
          pipeline
          | on_progress: fn event ->
              if previous, do: previous.(event)
              track(run_id, event)
            end,
            cancel: fn ->
              Store.get_run(run_id).cancel_requested? or
                (previous_cancel != nil and previous_cancel.())
            end
        }

        terminal(pipeline, mode, winner, split)
      end

    finish(run_id, outcome)
  rescue
    error -> finish(run_id, {:error, error})
  catch
    kind, reason -> finish(run_id, {:error, {kind, reason}})
  end

  defp run_splits(%{runner: nil, data: data}, :tune, _split),
    do: Enum.filter([:train, :validation], &Map.has_key?(data, &1))

  defp run_splits(_pipeline, :tune, _split), do: [:validation]
  defp run_splits(_pipeline, _mode, split), do: [split]

  defp terminal(pipeline, :tune, _winner, _split) do
    with {:ok, result} <- Tune.tune(pipeline) do
      case Tune.dump(result) do
        {:ok, artifact} -> {:ok, result, artifact}
        {:error, error} -> {:ok, result, nil, error}
      end
    end
  end

  defp terminal(pipeline, :compare, winner, split),
    do: Tune.compare(pipeline, winner, split: split)

  defp terminal(pipeline, :evaluate, _winner, split), do: Tune.evaluate(pipeline, split)

  defp track(id, %{event: :rows_evaluated, rows: rows}), do: increment(id, :rows, length(rows))
  defp track(id, %{event: :candidate_evaluated}), do: increment(id, :candidates, 1)
  defp track(id, %{event: :generation_evaluated}), do: increment(id, :generations, 1)
  defp track(_id, _event), do: :ok

  defp increment(id, key, amount) do
    progress = Store.get_run(id).progress
    Store.update_run(id, %{progress: Map.update!(progress, key, &(&1 + amount))})
  end

  defp finish(run_id, {:ok, result, artifact}), do: finish(run_id, {:ok, result, artifact, nil})

  defp finish(run_id, {:ok, result, artifact, error}) do
    Store.update_run(run_id, %{
      status: status(result),
      result: result,
      artifact: artifact,
      error: error,
      finished_at: DateTime.utc_now()
    })
  end

  defp finish(run_id, {:ok, result}), do: finish(run_id, {:ok, result, nil})

  defp finish(
         run_id,
         {:error,
          %Tune.Error.Optimization.Failed{report: %Tune.Result{stop_reason: :cancelled} = report}}
       ),
       do: finish(run_id, {:ok, report})

  defp finish(
         run_id,
         {:error, %Tune.Error.Optimization.Failed{report: %Tune.Result{} = report} = error}
       ) do
    Store.update_run(run_id, %{
      status: :failed,
      result: report,
      error: error,
      finished_at: DateTime.utc_now()
    })
  end

  defp finish(run_id, {:error, error}) do
    Store.update_run(run_id, %{status: :failed, error: error, finished_at: DateTime.utc_now()})
  end

  defp status(%{stop_reason: :cancelled}), do: :cancelled
  defp status(%{baseline: %{stop_reason: :cancelled}}), do: :cancelled
  defp status(%{challenger: %{stop_reason: :cancelled}}), do: :cancelled
  defp status(_result), do: :completed
end
