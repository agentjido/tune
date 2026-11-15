defmodule Tune.Search.Study do
  @moduledoc """
  Shared state for program and genetic search runs.

  A Study owns limits, accounting, candidate identity, history, the incumbent,
  local random state, stop state, and result construction. It does not know a
  search algorithm or a runtime program type.
  """

  alias Tune.Candidate
  alias Tune.Evaluation
  alias Tune.Prediction
  alias Tune.Result

  defstruct [
    :budget,
    :max_model_calls,
    :deadline,
    :started_at,
    :stop_reason,
    :rand,
    :seed,
    limits: %{},
    calls: %{},
    usage: %{input: 0, output: 0, total: 0},
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

    %__MODULE__{
      budget: max_model_calls,
      max_model_calls: max_model_calls,
      deadline: Keyword.get(opts, :deadline, Map.get(limits, :deadline)),
      started_at: System.monotonic_time(:millisecond),
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
      deadline?(study) ->
        :deadline

      study.budget == 0 ->
        :model_call_limit

      evaluation_limit?(study) ->
        :evaluation_limit

      study.stop_reason in [:budget_exhausted, :model_call_limit, :lost_accounting, :deadline] ->
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
  def remaining_deadline(%__MODULE__{deadline: nil}), do: nil
  def remaining_deadline(%__MODULE__{deadline: :infinity}), do: nil

  def remaining_deadline(%__MODULE__{deadline: deadline, started_at: started_at}) do
    max(deadline - (System.monotonic_time(:millisecond) - started_at), 0)
  end

  @spec account(t(), Prediction.t()) :: t()
  def account(%__MODULE__{} = study, %Prediction{} = prediction) do
    used = Prediction.total_calls(prediction)
    tokens = Prediction.token_totals(prediction)

    %{
      study
      | calls: merge_counts(study.calls, prediction.calls),
        budget: subtract(study.budget, used),
        usage: add_usage(study.usage, tokens)
    }
  end

  @spec account_evaluation(t(), Evaluation.t()) :: t()
  def account_evaluation(%__MODULE__{} = study, %Evaluation{} = evaluation) do
    used = evaluation.calls |> Map.values() |> Enum.sum()

    %{
      study
      | calls: merge_counts(study.calls, evaluation.calls),
        budget: subtract(study.budget, used),
        usage: add_usage(study.usage, evaluation.usage),
        evaluations: study.evaluations + 1
    }
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

  @spec record_candidate(t(), Candidate.t()) :: t()
  def record_candidate(%__MODULE__{} = study, %Candidate{} = candidate) do
    best =
      if eligible?(candidate) and better?(candidate, study.best),
        do: candidate,
        else: study.best

    %{study | candidates: [candidate | study.candidates], best: best, next_id: study.next_id + 1}
  end

  @spec incumbent(t()) :: Candidate.t() | nil
  def incumbent(%__MODULE__{best: best}), do: best

  @spec best_evaluation(t()) :: Evaluation.t() | nil
  def best_evaluation(%__MODULE__{best: %Candidate{evaluation: evaluation}}), do: evaluation
  def best_evaluation(%__MODULE__{}), do: nil

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
      metadata: Map.merge(study.metadata, Keyword.get(opts, :metadata, %{}))
    }
  end

  @spec stop(t(), atom()) :: t()
  def stop(%__MODULE__{stop_reason: nil} = study, :budget_exhausted) do
    if deadline?(study),
      do: %{study | stop_reason: :deadline},
      else: %{study | stop_reason: :budget_exhausted}
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

  defp deadline?(%__MODULE__{deadline: nil}), do: false
  defp deadline?(%__MODULE__{deadline: :infinity}), do: false

  defp deadline?(%__MODULE__{deadline: deadline, started_at: started_at})
       when is_integer(deadline),
       do: System.monotonic_time(:millisecond) - started_at >= deadline

  defp evaluation_limit?(%__MODULE__{limits: limits, evaluations: evaluations}) do
    case Map.get(limits, :evaluations) do
      limit when is_integer(limit) -> evaluations >= limit
      _ -> false
    end
  end

  defp subtract(nil, _used), do: nil
  defp subtract(budget, used), do: max(budget - used, 0)

  defp merge_counts(left, right),
    do: Map.merge(left, right, fn _role, left_count, right_count -> left_count + right_count end)

  defp add_usage(left, right),
    do: %{
      input: left.input + right.input,
      output: left.output + right.output,
      total: left.total + right.total
    }
end
