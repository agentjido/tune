defmodule Tune.Comparison do
  @moduledoc """
  The paired evidence for an original target and a search winner.

  Each row contains the observations for both targets and one change per
  metric. Changes use the metric's direction. The delta is always the winner's
  value minus the original value. Aggregate means and deltas use only pairs
  where both scores are available. Each evaluation also keeps its own full
  summaries, model calls, and token usage.

  `case_ids` preserves dataset order. `rows` is keyed by these IDs. A missing
  or stopped observation yields an unpaired metric. A failed metric yields an
  error, while other metrics on the same row can still be compared.
  """

  alias Tune.Evaluation

  @enforce_keys [:split, :case_ids, :rows, :metrics, :baseline, :challenger, :complete?]
  defstruct @enforce_keys

  @type classification :: :improved | :regressed | :tied | :error | :unpaired
  @type t :: %__MODULE__{
          split: :train | :validation | :test,
          case_ids: [String.t()],
          rows: %{optional(String.t()) => map()},
          metrics: %{optional(atom()) => map()},
          baseline: Evaluation.t(),
          challenger: Evaluation.t(),
          complete?: boolean()
        }

  @doc false
  def build(split, cases, scores, baseline, challenger) do
    originals = Map.new(baseline.observations, &{&1.id, &1})
    winners = Map.new(challenger.observations, &{&1.id, &1})
    ids = Enum.map(cases, & &1.id)

    rows =
      Map.new(ids, fn id ->
        original = originals[id]
        winner = winners[id]
        changes = Map.new(scores, &{&1.name, row_change(&1, original, winner)})
        {id, %{baseline: original, challenger: winner, metrics: changes}}
      end)

    %__MODULE__{
      split: split,
      case_ids: ids,
      baseline: baseline,
      challenger: challenger,
      rows: rows,
      metrics: Map.new(scores, &{&1.name, summarize(&1, ids, rows)}),
      complete?: baseline.complete? and challenger.complete?
    }
  end

  defp row_change(score, original, winner) do
    left = original && original.scores[score.name]
    right = winner && winner.scores[score.name]

    {delta, status} =
      cond do
        is_number(left) and is_number(right) ->
          {right - left, classify(right - left, score.direction)}

        failed?(original, score.name) or failed?(winner, score.name) ->
          {nil, :error}

        true ->
          {nil, :unpaired}
      end

    %{baseline: left, challenger: right, delta: delta, status: status}
  end

  defp failed?(nil, _name), do: false

  defp failed?(observation, name) do
    Map.has_key?(observation.score_errors, name) or
      (observation.status == :error and map_size(observation.score_errors) == 0)
  end

  defp summarize(score, ids, rows) do
    changes = Enum.map(ids, &rows[&1].metrics[score.name])
    paired = Enum.filter(changes, &is_number(&1.delta))
    delta = mean(paired, :delta)

    %{
      direction: score.direction,
      baseline_mean: mean(paired, :baseline),
      challenger_mean: mean(paired, :challenger),
      delta: delta,
      status: if(delta, do: classify(delta, score.direction), else: :unpaired),
      counts: Enum.frequencies_by(changes, & &1.status)
    }
  end

  defp classify(delta, _direction) when delta == 0, do: :tied
  defp classify(delta, :maximize) when delta > 0, do: :improved
  defp classify(delta, :minimize) when delta < 0, do: :improved
  defp classify(_delta, _direction), do: :regressed

  defp mean([], _key), do: nil
  defp mean(changes, key), do: Enum.sum_by(changes, &Map.fetch!(&1, key)) / length(changes)
end
