defmodule Tune.Examples.SearchDemos do
  @moduledoc "Compare random and native TPE search on one ticket fixture."

  alias Tune.Examples.Support.{Offline, Tickets}
  alias Tune.Examples.Support.Transport

  def search(method, opts \\ []) do
    target =
      Transport.respond_with(fn body ->
        prompt = Transport.prompt_text(body)
        label = if prompt =~ "\ninvoice 5\n", do: "billing", else: "bug"
        Transport.chat(label: label)
      end)

    {strategy, options} = strategy(method)

    Tune.new(Tickets.classifier(),
      model: Offline.model(target),
      teacher: Offline.model(billing_teacher())
    )
    |> Tune.data(train: Tickets.billing(6), validation: Tickets.billing(2, "held-out dispute"))
    |> Tune.score(:route, &Tickets.exact/2, argument: :output)
    |> Tune.search(
      strategy,
      [accept_score: 1, max_bootstrapped_demos: 1, max_labeled_demos: 0] ++ options
    )
    |> Tune.limit(model_calls: Keyword.get(opts, :model_calls, 200), seed: 11)
    |> Tune.tune()
  end

  defp strategy(:random),
    do: {:bootstrap_few_shot_random_search, [num_candidate_programs: 8]}

  defp strategy(:tpe),
    do: {:bootstrap_few_shot_optuna, [num_demo_sets: 6, num_trials: 12, n_startup: 3]}

  defp billing_teacher, do: Transport.respond_with(fn _ -> Transport.chat(label: "billing") end)
end
