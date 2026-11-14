defmodule Tune.Optimizers.Playbook do
  @moduledoc """
  Learns a bounded list of lessons stored in a declared JSON parameter.

  The parameter must hold a list of strings that application code reads with
  `Tune.Execution.value/2` during its normal calls. The unchanged
  program is evaluated on validation first. Each round runs the incumbent on
  the training set, sends the current lessons and the trajectories with
  scores and feedback to the proposal role, and receives a new lesson list.
  A proposal is rejected unless it satisfies the parameter schema and the
  growth limits: at most `max_lessons` lessons, at most `max_new` lessons not
  already present, each at most `max_lesson_bytes`, and at most
  `max_total_bytes` in total. An accepted challenger is evaluated on
  validation against the incumbent, and the better complete eligible program
  is kept; a rejected or worse challenger leaves the incumbent unchanged.

  Options: `:parameter` (required name), `:rounds` (default 2),
  `:max_lessons` (default 8), `:max_new` (default 3), `:max_lesson_bytes`
  (default 400), `:max_total_bytes` (default 4 000).

  Differences from Imp: lessons are an ordinary parameter, not serving
  memory; there is no separate promotion or audit workflow and no
  checkpoints; serving state changes only when the caller installs the
  returned program or artifact.
  """

  @behaviour Tune.Optimizer

  alias Tune.Optimizer.Context
  alias Tune.Optimizers.Proposals
  alias Tune.Optimizers.Reflective
  alias Tune.Optimizers.Shared
  alias Tune.Parameter

  @options [:parameter, :rounds, :max_lessons, :max_new, :max_lesson_bytes, :max_total_bytes]

  @impl true
  def init(opts) do
    defaults = [
      parameter: nil,
      rounds: 2,
      max_lessons: 8,
      max_new: 3,
      max_lesson_bytes: 400,
      max_total_bytes: 4_000
    ]

    with {:ok, opts} <- Shared.require_options(opts, @options, defaults),
         :ok <-
           Shared.with_checks(
             [
               fn ->
                 if is_binary(opts[:parameter]),
                   do: :ok,
                   else: Shared.option_error(:parameter, "is required")
               end
             ] ++
               Enum.map(
                 [:rounds, :max_lessons, :max_new, :max_lesson_bytes, :max_total_bytes],
                 fn key -> fn -> Shared.positive(opts, key) end end
               )
           ) do
      {:ok, Map.new(opts)}
    end
  end

  @impl true
  def requirements(_config),
    do: %{datasets: [:train, :val], roles: [:proposal], model_calls?: true}

  @impl true
  def compile(config, program, %Context{} = ctx) do
    with {:ok, %Parameter{} = parameter} <-
           Map.new(Shared.values(program)) |> Map.fetch(config.parameter),
         {:ok, _} <- Parameter.validate(parameter.schema, ["probe"]) do
      {evaluation, ctx} = Context.evaluate(ctx, program, ctx.valset)

      {_id, ctx} =
        Context.consider(ctx, program, evaluation, %{label: "baseline", lessons: parameter.value})

      ctx = rounds(config, program, ctx, 1, [])
      ctx = if Context.exhausted?(ctx), do: Context.stop(ctx, :budget_exhausted), else: ctx
      Context.best(ctx)
    else
      _ ->
        {:error,
         elem(
           Shared.option_error(
             :parameter,
             "#{inspect(config.parameter)} must be a declared list-of-strings parameter"
           ),
           1
         ), ctx}
    end
  end

  @doc "Checks a proposed lesson list against the growth limits."
  @spec check_growth(map(), [String.t()], [String.t()]) :: :ok | {:error, String.t()}
  def check_growth(config, current, proposed) do
    new = Enum.reject(proposed, &(&1 in current))

    cond do
      Enum.any?(proposed, &(&1 == "")) ->
        {:error, "empty lesson"}

      length(proposed) > config.max_lessons ->
        {:error, "more than #{config.max_lessons} lessons"}

      length(new) > config.max_new ->
        {:error, "more than #{config.max_new} new lessons"}

      Enum.any?(proposed, &(byte_size(&1) > config.max_lesson_bytes)) ->
        {:error, "a lesson exceeds #{config.max_lesson_bytes} bytes"}

      Enum.sum(Enum.map(proposed, &byte_size/1)) > config.max_total_bytes ->
        {:error, "lessons exceed #{config.max_total_bytes} bytes"}

      true ->
        :ok
    end
  end

  defp rounds(config, _program, ctx, round, log) when round > config.rounds,
    do: Context.note(ctx, :rounds, Enum.reverse(log))

  defp rounds(config, program, ctx, round, log) do
    if Context.exhausted?(ctx) do
      Context.note(ctx, :rounds, Enum.reverse(log))
    else
      incumbent = incumbent(ctx, program)
      current = lessons(incumbent, config.parameter)
      {traces, ctx} = Reflective.traces(incumbent, ctx.trainset, ctx)
      task = "Lessons for the program parameter #{inspect(config.parameter)}."

      {proposed, ctx} =
        Proposals.lessons(ctx, task, current, Reflective.render(traces), config.max_lessons)

      with proposed when is_list(proposed) <- proposed,
           :ok <- check_growth(config, current, proposed),
           {:ok, challenger} <- Shared.put_value(incumbent, config.parameter, proposed),
           false <- Context.exhausted?(ctx) do
        {evaluation, ctx} = Context.evaluate(ctx, challenger, ctx.valset)

        {_id, ctx} =
          Context.consider(ctx, challenger, evaluation, %{
            label: "round_#{round}",
            lessons: proposed
          })

        rounds(config, program, ctx, round + 1, [
          %{round: round, accepted?: true, lessons: proposed} | log
        ])
      else
        {:error, reason} ->
          rounds(config, program, ctx, round + 1, [
            %{round: round, accepted?: false, reason: describe(reason)} | log
          ])

        _ ->
          rounds(config, program, ctx, round + 1, [
            %{round: round, accepted?: false, reason: "no valid proposal"} | log
          ])
      end
    end
  end

  defp incumbent(ctx, program) do
    case Context.best(ctx) do
      {:ok, best, _ctx} -> best
      {:error, _, _ctx} -> program
    end
  end

  defp lessons(program, name),
    do: Map.new(Shared.values(program)) |> Map.fetch!(name) |> then(& &1.value)

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason) when is_exception(reason), do: Exception.message(reason)
  defp describe(reason), do: inspect(reason)
end
