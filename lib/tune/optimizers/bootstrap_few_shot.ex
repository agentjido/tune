defmodule Tune.Optimizers.BootstrapFewShot do
  @moduledoc """
  Builds demonstrations from successful teacher trajectories.

  The teacher is the program with labeled demonstrations (as LabeledFewShot
  with `k: max_labeled_demos`, unsampled), run under the explicit `:teacher`
  model configuration. For each training row, demonstrations built from that
  same row are removed from the teacher first. A trajectory is accepted only
  when the whole program succeeds and, when a metric is given, its score is at
  least `accept_score`. The final successful call of each predictor in an
  accepted trajectory becomes that predictor's bootstrapped demonstration,
  including intermediate predictors. Remaining slots are filled with labeled
  demonstrations from rows that were not bootstrapped.

  Options:

    * `:accept_score` - required when a metric is given
    * `:max_bootstrapped_demos` - default 4
    * `:max_labeled_demos` - default 16
    * `:max_rounds` - passes over rows that were not yet accepted, default 1

  The build is complete when every predictor has `max_bootstrapped_demos`
  bootstrapped demonstrations or every row was tried in every round. A build
  stopped by the call limit is an error with its partial report.

  Differences from DSPy: rounds do not vary temperature or bypass caches;
  callers control provider caching explicitly through request options.
  """

  @behaviour Tune.Search.ProgramStrategy

  alias Tune.Optimizers.LabeledFewShot
  alias Tune.Optimizers.Shared
  alias Tune.Search.Program.Context

  @options Zoi.keyword(
             [
               max_bootstrapped_demos: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(4),
               max_labeled_demos: Zoi.integer() |> Zoi.gte(0) |> Zoi.default(16),
               max_rounds: Zoi.integer() |> Zoi.positive() |> Zoi.default(1),
               accept_score: Zoi.number() |> Zoi.nullable() |> Zoi.default(nil)
             ],
             unrecognized_keys: :error
           )

  @impl true
  def init(opts), do: Shared.options(@options, opts)

  @impl true
  def requirements(_config),
    do: %{datasets: [:train], roles: [:teacher], model_calls?: true, metric?: false}

  @impl true
  def compile(config, program, %Context{} = ctx) do
    case check_accept_score(config, ctx) do
      :ok -> build(config, program, ctx.train, ctx)
      {:error, error} -> {:error, error, ctx}
    end
  end

  @doc """
  Builds bootstrapped demonstrations from `examples` and returns the program
  with them. Reused by search optimizers and KNNFewShot.
  """
  @spec build(map(), Tune.t(), [Tune.Case.t()], Context.t()) ::
          {:ok, Tune.t(), Context.t()} | {:error, term(), Context.t()}
  def build(config, program, examples, ctx) do
    names = Enum.map(Shared.predictors(program), &elem(&1, 0))

    {labeled, ctx} =
      LabeledFewShot.build(%{k: config.max_labeled_demos, sample: false}, program, examples, ctx)

    teacher = Shared.put_demos(program, labeled)
    state = %{bootstrapped: Map.new(names, &{&1, []}), accepted: MapSet.new(), attempts: 0}

    case rounds(config, teacher, names, examples, ctx, state, config.max_rounds) do
      {:ok, state, ctx} ->
        {raw, ctx} = raw_demos(config, program, examples, state, ctx)

        demos =
          Map.new(names, fn name ->
            boot =
              Enum.take(Enum.reverse(state.bootstrapped[name]), config.max_bootstrapped_demos)

            fill = Enum.take(raw[name] || [], max(config.max_labeled_demos - length(boot), 0))
            {name, boot ++ fill}
          end)

        ctx =
          ctx
          |> Context.note(
            :bootstrapped,
            Map.new(state.bootstrapped, fn {n, d} ->
              {n, min(length(d), config.max_bootstrapped_demos)}
            end)
          )
          |> Context.note(:accepted_rows, MapSet.size(state.accepted))
          |> Context.note(:teacher_attempts, state.attempts)

        {:ok, Shared.put_demos(program, demos), ctx}

      {:error, error, state, ctx} ->
        ctx =
          ctx
          |> Context.note(
            :bootstrapped,
            Map.new(state.bootstrapped, fn {n, d} -> {n, length(d)} end)
          )
          |> Context.note(:teacher_attempts, state.attempts)

        {:error, error, ctx}
    end
  end

  defp rounds(_config, _teacher, _names, _examples, ctx, state, 0), do: {:ok, state, ctx}

  defp rounds(config, teacher, names, examples, ctx, state, left) do
    case pass(config, teacher, names, examples, ctx, state) do
      {:ok, state, ctx} ->
        if full?(state, config),
          do: {:ok, state, ctx},
          else: rounds(config, teacher, names, examples, ctx, state, left - 1)

      error ->
        error
    end
  end

  defp pass(config, teacher, names, examples, ctx, state) do
    Enum.reduce_while(examples, {:ok, state, ctx}, fn example, {:ok, state, ctx} ->
      cond do
        full?(state, config) ->
          {:halt, {:ok, state, ctx}}

        MapSet.member?(state.accepted, example.id) ->
          {:cont, {:ok, state, ctx}}

        Context.exhausted?(ctx) ->
          {:halt, {:error, Context.limit_error(), state, ctx}}

        true ->
          {outcome, ctx} =
            Context.run(ctx, Shared.without_row_demos(teacher, example), example.input, :teacher)

          state = %{state | attempts: state.attempts + 1}

          {acceptance, ctx} = accept(outcome, example, config, ctx)

          case acceptance do
            {:ok, result} ->
              demos = Shared.trajectory_demos(result, names)

              bootstrapped =
                Enum.reduce(demos, state.bootstrapped, fn {name, demo}, acc ->
                  Map.update!(acc, name, &[demo | &1])
                end)

              {:cont,
               {:ok,
                %{
                  state
                  | bootstrapped: bootstrapped,
                    accepted: MapSet.put(state.accepted, example.id)
                }, ctx}}

            :rejected ->
              if Context.exhausted?(ctx),
                do: {:halt, {:error, Context.limit_error(), state, ctx}},
                else: {:cont, {:ok, state, ctx}}
          end
      end
    end)
  end

  defp accept({:ok, result}, _example, _config, %Context{scores: []} = ctx),
    do: {{:ok, result}, ctx}

  defp accept({:ok, result}, example, config, ctx) do
    {outcome, ctx} = Context.score(ctx, example, result)

    case outcome do
      {:ok, %{score: score}} when score >= config.accept_score -> {{:ok, result}, ctx}
      _ -> {:rejected, ctx}
    end
  end

  defp accept({:error, _error}, _example, _config, ctx), do: {:rejected, ctx}

  defp full?(state, config) do
    Enum.all?(state.bootstrapped, fn {_name, demos} ->
      length(demos) >= config.max_bootstrapped_demos
    end)
  end

  defp raw_demos(config, program, examples, state, ctx) do
    remaining = Enum.reject(examples, &MapSet.member?(state.accepted, &1.id))
    LabeledFewShot.build(%{k: config.max_labeled_demos, sample: true}, program, remaining, ctx)
  end

  defp check_accept_score(%{accept_score: nil}, %Context{scores: [_ | _]}),
    do: Shared.option_error(:accept_score, "is required when a metric is given")

  defp check_accept_score(_config, _ctx), do: :ok
end
