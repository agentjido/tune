defmodule Tune.Examples.Voting do
  @moduledoc "Combine classifiers with one shared call ceiling."

  alias Tune.Examples.Support.{Offline, Tickets}
  alias Tune.Examples.Support.Transport

  def ensemble(votes \\ ["bug", "billing", "billing"], max_calls \\ 3) do
    members =
      votes
      |> Enum.with_index(1)
      |> Enum.map(fn {_label, index} -> Tickets.classifier("Use voter #{index}.") end)

    {:ok, ensemble} = Tune.Ensemble.new(members)
    stub = Transport.script(Enum.map(votes, &Transport.chat(label: &1)))

    Tune.Runtime.run(ensemble, %{ticket: "My card was charged twice"},
      model: Offline.model(stub),
      max_model_calls: max_calls
    )
  end
end
