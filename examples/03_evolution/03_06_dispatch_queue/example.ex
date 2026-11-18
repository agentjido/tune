defmodule Tune.Examples.Dispatch do
  @moduledoc "Evolve a queue policy and report complete and interrupted generations."

  @queue [
    %{id: :report, duration: 4, due: 10, priority: 4},
    %{id: :payment, duration: 1, due: 1, priority: 3},
    %{id: :confirm, duration: 2, due: 3, priority: 2},
    %{id: :archive, duration: 1, due: 8, priority: 1}
  ]

  def run(opts \\ []) do
    observer = Keyword.get(opts, :on_progress, fn _ -> :ok end)
    strategy = Keyword.take(opts, [:patience, :cancel, :mutate, :generations])
    runner = Keyword.get(opts, :runner, &simulate/2)

    Tune.new(:fifo, run: runner, on_progress: observer)
    |> Tune.data(validation: [@queue])
    |> Tune.score(:on_time, & &1.on_time)
    |> Tune.search(
      :genetic,
      Keyword.merge(
        [
          initial_population: [:fifo, :priority, :fifo],
          mutate: fn _policy, rng -> {:deadline, rng} end,
          mutation_rate: 1,
          elitism: 0,
          generations: 2,
          patience: 1
        ],
        strategy
      )
    )
    |> Tune.limit(Keyword.merge([evaluations: 9, seed: 12], Keyword.take(opts, [:deadline])))
    |> Tune.tune()
  end

  def simulate(policy, queue) do
    ordered =
      case policy do
        :fifo -> queue
        :priority -> Enum.sort_by(queue, & &1.priority, :desc)
        :deadline -> Enum.sort_by(queue, & &1.due)
      end

    {trace, _elapsed} =
      Enum.map_reduce(ordered, 0, fn job, elapsed ->
        finished = elapsed + job.duration
        {{job.id, finished <= job.due}, finished}
      end)

    %{order: Enum.map(trace, &elem(&1, 0)), on_time: Enum.count(trace, &elem(&1, 1))}
  end
end
