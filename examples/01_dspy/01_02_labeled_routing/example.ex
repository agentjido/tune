defmodule Tune.Examples.LabeledRouting do
  @moduledoc "Learn a banking support router from labeled tickets."

  alias Tune.Examples.Support.{Offline, Tickets}
  alias Tune.Examples.Support.{QAWorld, Transport}

  def labeled(opts \\ []) do
    target =
      Transport.respond_with(fn body ->
        ticket = Offline.field(Transport.last_user_text(body), "ticket")
        label = if QAWorld.demos?(body), do: Tickets.banking_label(ticket), else: "unrouted"
        Transport.chat(label: label)
      end)

    study =
      Tune.new(Tickets.classifier(), model: Offline.model(target))
      |> Tune.data(
        train: Keyword.get(opts, :train, Tickets.banking()),
        test:
          Tickets.rows([
            {"I cannot find my card", "lost_card"},
            {"The ATM did not give me cash", "cash_withdrawal"},
            {"Why is there a purchase fee?", "card_payment_fee"}
          ])
      )
      |> Tune.score(:route, &Tickets.exact/2, argument: :output)
      |> Tune.search(:labeled_few_shot, k: 4)
      |> Tune.limit(seed: Keyword.get(opts, :seed, 5), model_calls: 12)

    {:ok, winner} = Tune.tune(study)
    search_requests = Transport.requests(target)
    {:ok, holdout} = Tune.compare(study, winner, split: :test)
    %{winner: winner, holdout: holdout, search_requests: search_requests}
  end
end
