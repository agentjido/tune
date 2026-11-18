defmodule Tune.Examples.SIMBA do
  @moduledoc "Improve variable routing with demonstrations or rules."

  alias Tune.Examples.Support.{Offline, Tickets}
  alias Tune.Examples.Support.{QAWorld, Transport}

  def simba(path) do
    target = Transport.respond_with(fn body -> simba_reply(path, body) end)

    proposal =
      Transport.respond_with(fn _ -> Transport.chat(feedback: "Always answer billing.") end)

    mode = if path == :rule, do: :append_a_rule, else: :append_a_demo

    Tune.new(Tickets.classifier("Label it."),
      model: Offline.model(target),
      proposal: Offline.model(proposal)
    )
    |> Tune.data(
      train:
        Tickets.rows([
          {"easy invoice", "billing"},
          {"easy payment", "billing"},
          {"hard case", "billing"}
        ]),
      validation: Tickets.rows([{"new easy invoice", "billing"}, {"new hard invoice", "billing"}])
    )
    |> Tune.score(:route, &Tickets.exact/2, argument: :output)
    |> Tune.search(:simba,
      bsz: 3,
      num_candidates: 2,
      max_steps: 2,
      num_final: 2,
      strategies: [mode]
    )
    |> Tune.limit(model_calls: 100, seed: 1)
    |> Tune.tune()
  end

  defp simba_reply(:failed, _body), do: {:text, "unparseable"}

  defp simba_reply(_path, body) do
    prompt = Transport.prompt_text(body)
    user = Transport.last_user_text(body)
    helps? = user =~ "easy" or QAWorld.demos?(body) or prompt =~ "Always answer billing."
    Transport.chat(label: if(helps?, do: "billing", else: "bug"))
  end
end
