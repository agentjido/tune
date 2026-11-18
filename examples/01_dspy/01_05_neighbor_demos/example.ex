defmodule Tune.Examples.NeighborDemos do
  @moduledoc "Bootstrap demonstrations from the nearest tickets."

  alias Tune.Examples.Support.{Offline, Tickets}
  alias Tune.Examples.Support.{QAWorld, Transport}

  def neighbors(tickets, opts \\ []) do
    pool =
      Tickets.rows([
        {"refund my card payment", "billing"},
        {"the app crashes on start", "bug"},
        {"invoice payment failed twice", "billing"}
      ])

    teacher =
      Transport.respond_with(fn body ->
        label = if Transport.last_user_text(body) =~ "crash", do: "bug", else: "billing"
        Transport.chat(label: label)
      end)

    target =
      Transport.respond_with(fn body ->
        label =
          if QAWorld.demos?(body) and Transport.prompt_text(body) =~ "the app crashes on start",
            do: "bug",
            else: "billing"

        Transport.chat(label: label)
      end)

    {:ok, winner} =
      Tune.new(Tickets.classifier(), model: Offline.model(target))
      |> Tune.data(train: pool)
      |> Tune.search(:knn_few_shot, k: Keyword.get(opts, :k, 1))
      |> Tune.tune()

    results =
      Enum.map(tickets, fn ticket ->
        Tune.Runtime.run(winner.value, %{ticket: ticket},
          model: Offline.model(target),
          teacher: Offline.model(teacher),
          max_model_calls: Keyword.get(opts, :model_calls, 6)
        )
      end)

    %{results: results, teacher_requests: Transport.requests(teacher)}
  end
end
