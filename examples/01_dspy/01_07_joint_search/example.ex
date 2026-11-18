defmodule Tune.Examples.JointSearch do
  @moduledoc "Tune instructions and demonstration sets in one search."

  alias Tune.Examples.Support.{Offline, Tickets}
  alias Tune.Examples.Support.{QAWorld, Transport}

  def mipro(opts \\ []) do
    target =
      Transport.respond_with(fn body ->
        prompt = Transport.prompt_text(body)
        user = Transport.last_user_text(body)

        label =
          cond do
            prompt =~ "Memorize" and user =~ "\nticket " -> "billing"
            prompt =~ "Be exact" and QAWorld.demos?(body) -> "billing"
            true -> "bug"
          end

        Transport.chat(label: label)
      end)

    proposal =
      Transport.respond_with(fn _ ->
        Transport.chat(instructions: ["Memorize the answers.", "Be exact."])
      end)

    Tune.new(Tickets.classifier("Label it."),
      model: Offline.model(target),
      teacher: Offline.model(billing_teacher()),
      proposal: Offline.model(proposal)
    )
    |> Tune.data(train: Tickets.billing(4, "ticket"), validation: Tickets.billing(3, "held out"))
    |> Tune.score(:route, &Tickets.exact/2, argument: :output)
    |> Tune.search(:mipro_v2,
      accept_score: 1.0,
      num_candidates: 3,
      num_trials: 10,
      minibatch_size: 2,
      minibatch_full_eval_steps: 3,
      n_startup: 3,
      max_labeled_demos: 0,
      max_bootstrapped_demos: 1
    )
    |> Tune.limit(model_calls: Keyword.get(opts, :model_calls, 300), seed: 5)
    |> Tune.tune()
  end

  defp billing_teacher, do: Transport.respond_with(fn _ -> Transport.chat(label: "billing") end)
end
