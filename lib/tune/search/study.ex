defmodule Tune.Search.Study do
  @moduledoc """
  Shared limits and accounting for Tune runs.

  A Study owns limits, accounting, candidate identity, history, the incumbent,
  local random state, stop state, and result construction. It does not know a
  search algorithm or a runtime program type.
  """

  alias Tune.Candidate
  alias Tune.Evaluation
  alias Tune.Result
  alias Tune.RunLimits

  defstruct [
    :budget,
    :max_model_calls,
    :expires_at,
    :stop_reason,
    :rand,
    :seed,
    limits: %{},
    calls: %{},
    usage: %{input: 0, output: 0, total: 0},
    successful_models: MapSet.new(),
    evaluations: 0,
    candidates: [],
    best: nil,
    next_id: 0,
    metadata: %{},
    notes: %{}
  ]

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    seed = Keyword.get(opts, :seed, 0)
    limits = Keyword.get(opts, :limits, %{})

    max_model_calls = Keyword.get(opts, :model_calls, Map.get(limits, :model_calls))
    deadline = Keyword.get(opts, :deadline, Map.get(limits, :deadline))

    %__MODULE__{
      budget: max_model_calls,
      max_model_calls: max_model_calls,
      expires_at: RunLimits.expiration(deadline),
      rand: :rand.seed_s(:exsss, seed),
      seed: seed,
      limits: limits,
      metadata: Keyword.get(opts, :metadata, %{}),
      notes: Keyword.get(opts, :notes, %{})
    }
  end

  @spec exhausted?(t()) :: boolean()
  def exhausted?(%__MODULE__{} = study), do: limit_reason(study) != nil

  @spec limit_reason(t()) :: atom() | nil
  def limit_reason(%__MODULE__{} = study) do
    cond do
      reason = RunLimits.stop_reason(study.expires_at, study.limits[:cancel]) ->
        reason

      study.budget == 0 ->
        :model_call_limit

      evaluation_limit?(study) ->
        :evaluation_limit

      study.stop_reason in [
        :budget_exhausted,
        :model_call_limit,
        :lost_accounting,
        :deadline,
        :cancelled,
        :evaluation_limit
      ] ->
        study.stop_reason

      true ->
        nil
    end
  end

  @spec remaining_model_calls(t()) :: non_neg_integer() | nil
  def remaining_model_calls(%__MODULE__{budget: budget}), do: budget

  @spec remaining_evaluations(t()) :: non_neg_integer() | nil
  def remaining_evaluations(%__MODULE__{limits: limits, evaluations: evaluations}) do
    case Map.get(limits, :evaluations) do
      limit when is_integer(limit) -> max(limit - evaluations, 0)
      _ -> nil
    end
  end

  @spec remaining_deadline(t()) :: non_neg_integer() | nil
  def remaining_deadline(%__MODULE__{expires_at: nil}), do: nil

  def remaining_deadline(%__MODULE__{expires_at: expires_at}), do: RunLimits.remaining(expires_at)

  @spec evaluation_limits(t()) :: map()
  def evaluation_limits(%__MODULE__{} = study) do
    study.limits
    |> Map.drop([:evaluations, :seed, :steps])
    |> Map.merge(%{
      model_calls: remaining_model_calls(study),
      deadline: remaining_deadline(study),
      expires_at: study.expires_at
    })
  end

  @spec account_evaluation(t(), Evaluation.t()) :: t()
  def account_evaluation(%__MODULE__{} = study, %Evaluation{} = evaluation) do
    study = account_score(study, evaluation)
    %{study | evaluations: study.evaluations + 1}
  end

  @spec account_score(t(), Evaluation.t()) :: t()
  def account_score(%__MODULE__{} = study, %Evaluation{} = evaluation) do
    used = evaluation.calls |> Map.values() |> Enum.sum()

    study = %{
      study
      | calls: merge_counts(study.calls, evaluation.calls),
        budget: subtract(study.budget, used),
        usage: add_usage(study.usage, evaluation.usage),
        successful_models:
          merge_models(study, Map.get(evaluation.metadata, :successful_models, []))
    }

    case evaluation.stop_reason do
      reason when reason in [:completed, :case_limit] -> study
      :model_call_limit -> stop(study, :budget_exhausted)
      reason -> stop(study, reason)
    end
  end

  @spec emit(t(), map()) :: :ok
  def emit(%__MODULE__{} = study, event) do
    if callback = study.limits[:on_progress], do: callback.(event)
    :ok
  end

  @spec record(t(), term(), map(), Evaluation.t() | nil, map()) :: {Candidate.t(), t()}
  def record(%__MODULE__{} = study, value, parameters, evaluation, attributes \\ %{}) do
    {lineage, metadata} =
      case attributes do
        %{lineage: lineage, metadata: metadata} -> {lineage, metadata}
        attributes -> Map.split(attributes, [:parents, :parent, :merged_from])
      end

    candidate = %Candidate{
      id: Integer.to_string(study.next_id),
      parameters: parameters,
      value: value,
      evaluation: evaluation,
      lineage: lineage,
      metadata: metadata
    }

    {candidate, record_candidate(study, candidate)}
  end

  defp record_candidate(study, candidate) do
    best =
      if eligible?(candidate) and better?(candidate, study.best),
        do: candidate,
        else: study.best

    %{study | candidates: [candidate | study.candidates], best: best, next_id: study.next_id + 1}
  end

  @spec incumbent(t()) :: Candidate.t() | nil
  def incumbent(%__MODULE__{best: best}), do: best

  @spec result(t(), term(), map(), keyword()) :: Result.t()
  def result(%__MODULE__{} = study, value, parameters, opts \\ []) do
    %Result{
      value: value,
      parameters: parameters,
      baseline: Keyword.get(opts, :baseline),
      best: study.best,
      history: Enum.reverse(study.candidates),
      complete?: Keyword.get(opts, :complete?, study.stop_reason == nil),
      stop_reason: Keyword.get(opts, :stop_reason, study.stop_reason || :completed),
      calls: study.calls,
      usage: study.usage,
      metadata:
        study.metadata
        |> Map.merge(Keyword.get(opts, :metadata, %{}))
        |> Map.put(:successful_models, Enum.sort(study.successful_models))
    }
  end

  @spec stop(t(), atom()) :: t()
  def stop(%__MODULE__{stop_reason: nil} = study, :budget_exhausted) do
    reason =
      case limit_reason(study) do
        other when other in [:deadline, :cancelled, :evaluation_limit] -> other
        _ -> :budget_exhausted
      end

    %{study | stop_reason: reason}
  end

  def stop(%__MODULE__{stop_reason: nil} = study, reason), do: %{study | stop_reason: reason}
  def stop(%__MODULE__{} = study, _reason), do: study

  @spec stop_reason(t()) :: atom() | nil
  def stop_reason(%__MODULE__{stop_reason: reason}), do: reason

  @spec note(t(), atom(), term()) :: t()
  def note(%__MODULE__{} = study, key, value),
    do: %{study | notes: Map.put(study.notes, key, value)}

  @spec notes(t()) :: map()
  def notes(%__MODULE__{notes: notes}), do: notes

  @spec uniform(t(), pos_integer()) :: {non_neg_integer(), t()}
  def uniform(%__MODULE__{} = study, n) when n > 0 do
    {value, rand} = :rand.uniform_s(n, study.rand)
    {value - 1, %{study | rand: rand}}
  end

  @spec random(t()) :: {float(), t()}
  def random(%__MODULE__{} = study) do
    {value, rand} = :rand.uniform_s(study.rand)
    {value, %{study | rand: rand}}
  end

  @spec random(t(), (term() -> {term(), term()})) :: {term(), t()}
  def random(%__MODULE__{} = study, operation) when is_function(operation, 1) do
    {value, rand} = operation.(study.rand)
    {value, %{study | rand: rand}}
  end

  @spec shuffle(t(), list()) :: {list(), t()}
  def shuffle(%__MODULE__{} = study, list) do
    {keyed, study} =
      Enum.map_reduce(list, study, fn item, study ->
        {key, study} = random(study)
        {{key, item}, study}
      end)

    {keyed |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)), study}
  end

  @spec sample(t(), list(), non_neg_integer()) :: {list(), t()}
  def sample(%__MODULE__{} = study, list, k) do
    {shuffled, study} = shuffle(study, list)
    {Enum.take(shuffled, k), study}
  end

  defp eligible?(%Candidate{evaluation: %Evaluation{complete?: true, eligible?: true}}), do: true
  defp eligible?(_candidate), do: false

  defp better?(_candidate, nil), do: true

  defp better?(candidate, best),
    do: candidate.evaluation.selected_score > best.evaluation.selected_score

  defp evaluation_limit?(%__MODULE__{limits: limits, evaluations: evaluations}) do
    case Map.get(limits, :evaluations) do
      limit when is_integer(limit) -> evaluations >= limit
      _ -> false
    end
  end

  defp subtract(nil, _used), do: nil
  defp subtract(budget, used), do: max(budget - used, 0)

  defp merge_models(study, models), do: Enum.into(models, study.successful_models)

  defp merge_counts(left, right),
    do: Map.merge(left, right, fn _role, left_count, right_count -> left_count + right_count end)

  defp add_usage(left, right),
    do: %{
      input: left.input + right.input,
      output: left.output + right.output,
      total: left.total + right.total
    }
end
