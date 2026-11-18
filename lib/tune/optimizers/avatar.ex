defmodule Tune.Optimizers.Avatar do
  @moduledoc """
  Contrastive instruction improvement for one named predictor.

  The unchanged program is evaluated on validation first. Then, for up to
  `max_iters` iterations, the current program runs on the training set.
  Trajectories scoring at least `upper_bound` are positive; failed runs and
  scores at most `lower_bound` are negative, so a failure is never positive.
  The proposal role compares up to `max_positive` positive and
  `max_negative` negative trajectories and writes feedback, then rewrites the
  named predictor's instruction from that feedback. Each rewrite is validated
  before it can be returned; only that predictor's instruction changes. If
  either group is empty the search stops cleanly with stop note
  `:no_contrast` and returns the best validated program.

  Options: `:predictor` (required name), `:upper_bound` and `:lower_bound`
  (required scores), `:max_iters` (default 3), `:max_positive` and
  `:max_negative` (default 5).

  Differences from DSPy: this operates on a declared predictor instruction and
  ordinary program traces; it needs no Avatar agent runtime or tools.
  """

  @behaviour Tune.Search.ProgramStrategy

  alias Tune.Optimizers.Proposals
  alias Tune.Optimizers.Reflective
  alias Tune.Optimizers.Shared
  alias Tune.Search.Program.Context

  @options Zoi.keyword(
             [
               predictor: Zoi.string() |> Zoi.required(),
               upper_bound: Zoi.number() |> Zoi.required(),
               lower_bound: Zoi.number() |> Zoi.required(),
               max_iters: Zoi.integer() |> Zoi.positive() |> Zoi.default(3),
               max_positive: Zoi.integer() |> Zoi.positive() |> Zoi.default(5),
               max_negative: Zoi.integer() |> Zoi.positive() |> Zoi.default(5)
             ],
             unrecognized_keys: :error
           )

  @impl true
  def init(opts) do
    with {:ok, config} <- Shared.options(@options, opts) do
      if config.lower_bound < config.upper_bound,
        do: {:ok, config},
        else: Shared.option_error(:lower_bound, "must be below upper_bound")
    end
  end

  @impl true
  def requirements(_config),
    do: %{datasets: [:train, :validation], roles: [:proposal], model_calls?: true}

  @impl true
  def compile(config, program, %Context{} = ctx) do
    case Map.new(Shared.predictors(program)) |> Map.fetch(config.predictor) do
      {:ok, predictor} ->
        {evaluation, ctx} = Context.evaluate_validation(ctx, program)
        {_id, ctx} = Context.consider(ctx, program, evaluation, %{label: "baseline"})
        task = Proposals.describe(predictor)
        ctx = iterate(config, task, program, ctx, 1, [])
        ctx = if Context.exhausted?(ctx), do: Context.stop(ctx, :budget_exhausted), else: ctx
        Context.best(ctx)

      :error ->
        {:error,
         elem(
           Shared.option_error(:predictor, "unknown predictor #{inspect(config.predictor)}"),
           1
         ), ctx}
    end
  end

  defp iterate(config, _task, _program, ctx, iteration, log) when iteration > config.max_iters,
    do: Context.note(ctx, :iterations, Enum.reverse(log))

  defp iterate(config, task, program, ctx, iteration, log) do
    if Context.exhausted?(ctx) do
      Context.note(ctx, :iterations, Enum.reverse(log))
    else
      {traces, ctx} = Reflective.traces(program, ctx.train, ctx)

      positive =
        traces
        |> Enum.filter(&(&1.error == nil and &1.score >= config.upper_bound))
        |> Enum.take(config.max_positive)

      negative =
        traces
        |> Enum.filter(&(&1.error != nil or &1.score <= config.lower_bound))
        |> Enum.take(config.max_negative)

      record = %{
        iteration: iteration,
        positive: Enum.map(positive, & &1.example.id),
        negative: Enum.map(negative, & &1.example.id)
      }

      if positive == [] or negative == [] do
        ctx
        |> Context.note(:stop, :no_contrast)
        |> Context.note(:iterations, Enum.reverse([record | log]))
      else
        current = instruction(program, config.predictor)

        {feedback, ctx} =
          Proposals.contrast(
            ctx,
            task,
            current,
            Reflective.render(positive),
            Reflective.render(negative)
          )

        {rewritten, ctx} =
          if feedback, do: Proposals.rewrite(ctx, task, current, feedback), else: {nil, ctx}

        case rewritten && Shared.put_instructions(program, %{config.predictor => rewritten}) do
          {:ok, candidate} ->
            {evaluation, ctx} = Context.evaluate_validation(ctx, candidate)

            {_id, ctx} =
              Context.consider(ctx, candidate, evaluation, %{
                label: "avatar_#{iteration}",
                feedback: feedback,
                instruction: rewritten
              })

            iterate(config, task, candidate, ctx, iteration + 1, [
              Map.put(record, :feedback, feedback) | log
            ])

          _ ->
            iterate(config, task, program, ctx, iteration + 1, [
              Map.put(record, :feedback, feedback) | log
            ])
        end
      end
    end
  end

  defp instruction(program, name),
    do:
      Map.new(Shared.predictors(program)) |> Map.fetch!(name) |> then(& &1.signature.instructions)
end
