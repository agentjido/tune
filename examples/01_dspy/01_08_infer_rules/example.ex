defmodule Tune.Examples.EscalationRules do
  @moduledoc "Learn candidate escalation rules and compare them on validation."

  alias Tune.Examples.Support.{Offline, Tickets}
  alias Tune.Examples.Support.{QAWorld, Transport}

  def infer_rules(rule \\ "Escalate an unrecognized charge immediately.") do
    train =
      Tickets.rows([
        {"Card used without permission", "escalate"},
        {"Charge I never made", "escalate"}
      ])

    validate =
      Tickets.rows([
        {"Unrecognized charge from last night", "escalate"},
        {"Question about invoice", "billing"}
      ])

    teacher = Transport.respond_with(fn _ -> Transport.chat(label: "escalate") end)
    proposal = Transport.respond_with(fn _ -> Transport.chat(rules: [rule]) end)

    target =
      Transport.respond_with(fn body ->
        user = Transport.last_user_text(body)
        prompt = Transport.prompt_text(body)

        label =
          cond do
            prompt =~ "Never escalate" -> "other"
            prompt =~ "Escalate an unrecognized" and user =~ "Unrecognized" -> "escalate"
            QAWorld.demos?(body) -> "escalate"
            true -> "other"
          end

        label =
          if user =~ "invoice" and prompt =~ "Escalate an unrecognized",
            do: "billing",
            else: label

        Transport.chat(label: label)
      end)

    Tune.new(Tickets.classifier(),
      model: Offline.model(target),
      teacher: Offline.model(teacher),
      proposal: Offline.model(proposal)
    )
    |> Tune.data(train: train, validation: validate)
    |> Tune.score(:route, &Tickets.exact/2, argument: :output)
    |> Tune.search(:infer_rules, accept_score: 1.0, num_candidates: 1, max_bootstrapped_demos: 2)
    |> Tune.limit(model_calls: 30, seed: 2)
    |> Tune.tune()
  end
end
