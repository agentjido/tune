defmodule Tune.Examples.RewriteInstructions do
  @moduledoc "Compare named and multi-predictor instruction search."

  alias Tune.Examples.Support.{GroundedQA, Offline}
  alias Tune.Examples.Support.{QAWorld, Transport}

  def rewrite(strategy) do
    target =
      QAWorld.stub(
        quality: fn prompt, answer ->
          if prompt =~ "Cite the passage id", do: answer, else: "unsure"
        end
      )

    proposal =
      Transport.respond_with(fn body ->
        options =
          if Transport.prompt_text(body) =~ "Outputs: `answer`",
            do: ["Cite the passage id and answer.", "Cite the passage id first."],
            else: ["Choose passages.", "Keep useful passages."]

        Transport.chat(instructions: options)
      end)

    opts = [breadth: 2, depth: 1]
    opts = if strategy == :signature_optimizer, do: [predictor: "answer"] ++ opts, else: opts

    Tune.new(GroundedQA.new(), model: Offline.model(target), proposal: Offline.model(proposal))
    |> Tune.data(
      train: QAWorld.rows([{"Which is Alpha?", "alpha", "first"}]),
      validation: QAWorld.rows([{"Which is Beta?", "beta", "second"}])
    )
    |> Tune.score(:answer, &QAWorld.metric/2)
    |> Tune.search(strategy, opts)
    |> Tune.limit(model_calls: 40)
    |> Tune.tune()
  end
end
