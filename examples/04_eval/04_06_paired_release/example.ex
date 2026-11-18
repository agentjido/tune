defmodule Tune.Examples.ReleaseGate do
  @moduledoc "Require paired evidence for the critical route before promotion."

  def run(opts \\ []) do
    original = %{policy: :baseline}

    study =
      Tune.new(original, run: &route/2)
      |> Tune.data(validation: [%{input: :standard, expected: "billing"}])
      |> Tune.vary(policy: [:baseline, :challenger])
      |> Tune.score(:route, fn row, output -> if row.expected == output, do: 1, else: 0 end)
      |> Tune.search(:grid)

    {:ok, winner} = Tune.tune(study)
    runner = Keyword.get(opts, :runner, &route/2)

    paired_study =
      Tune.new(original, run: runner)
      |> Tune.data(test: Keyword.get(opts, :holdout, &holdout/0))
      |> Tune.score(:route, fn row, output -> if row.expected == output, do: 1, else: 0 end)
      |> Tune.limit(Keyword.take(opts, [:deadline, :row_timeout, :row_calls, :model_calls]))

    with {:ok, paired} <- Tune.compare(paired_study, winner, split: :test) do
      {:ok, %{comparison: paired, decision: decide(paired)}}
    end
  end

  def holdout do
    [
      %{id: "critical", input: :critical, expected: "risk-review"},
      %{id: "standard", input: :standard, expected: "billing"},
      %{id: "overflow", input: :overflow, expected: "billing"}
    ]
  end

  def route(%{policy: :baseline}, :critical), do: "risk-review"
  def route(%{policy: :baseline}, _row), do: "general"
  def route(%{policy: :challenger}, :critical), do: "general"
  def route(%{policy: :challenger}, _row), do: "billing"

  defp decide(%{complete?: false}), do: :hold_incomplete

  defp decide(paired) do
    case get_in(paired.rows, ["critical", :metrics, :route, :status]) do
      :regressed ->
        :hold_critical_regression

      status when status in [:tied, :improved] ->
        if paired.metrics.route.status == :improved, do: :promote, else: :hold

      _ ->
        :hold_missing_critical_evidence
    end
  end
end
