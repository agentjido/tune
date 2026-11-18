defmodule Tune.Examples.Support.MultiHopQA do
  @moduledoc "Reflect on two-hop QA failures and validate complementary repairs."

  alias Tune.Examples.Support.{GroundedQA, Offline}
  alias Tune.Examples.Support.Transport

  def run(opts \\ []) do
    proposal = reflector(Keyword.get(opts, :proposal))
    strategy = Keyword.take(opts, [:max_iterations, :minibatch_size, :use_merge, :merge_every])

    study =
      Tune.new(GroundedQA.new(),
        model: Offline.model(target()),
        proposal: Offline.model(proposal)
      )
      |> Tune.data(train: rows("practice"), validation: rows("holdout"))
      |> Tune.score(:grounded, &grounded/2, argument: :output)
      |> Tune.search(
        :gepa,
        Keyword.merge([max_iterations: 6, minibatch_size: 2, merge_every: 3], strategy)
      )
      |> Tune.limit(model_calls: 320, seed: Keyword.get(opts, :seed, 0))

    {:ok, winner} = Tune.tune(study)
    %{winner: winner, reflection: Transport.requests(proposal)}
  end

  defp rows(split) do
    for {bridge, artist, country, gap} <- [
          {"Pine Bridge", "Nora Hill", "Canada", "missing evidence"},
          {"Copper Bridge", "Tomas Velez", "Chile", "unsupported answer"}
        ] do
      %{
        id: "#{split}-#{bridge}",
        input: %{
          question: "Which country was the designer of #{bridge} born in? (#{split})",
          context: [
            %{"id" => "design", "text" => "#{bridge} was designed by #{artist}."},
            %{"id" => "birth", "text" => "#{artist} was born in #{country}."},
            %{"id" => "noise", "text" => "The bridge is open during the day."}
          ]
        },
        expected: %{answer: country, sources: ["design", "birth"], gap: gap}
      }
    end
  end

  defp grounded(row, output) do
    cond do
      output["answer"] == row.expected["answer"] and output["sources"] == row.expected["sources"] ->
        %{score: 1, feedback: "Both evidence hops support the answer."}

      row.expected["gap"] == "missing evidence" ->
        %{score: 0, feedback: "missing evidence: retain the designer and birthplace passages"}

      true ->
        %{score: 0, feedback: "unsupported answer: connect both passages and cite both IDs"}
    end
  end

  defp target do
    Transport.respond_with(fn body ->
      user = Transport.last_user_text(body)
      prompt = body |> Transport.prompt_text()
      pine? = Offline.field(user, "question") =~ "Pine"

      case Offline.field(user, "context") do
        nil -> answer(user, pine?, prompt)
        context -> extract(context, pine?, prompt)
      end
    end)
  end

  defp extract(context, pine?, prompt) do
    [design, birth | _] = JSON.decode!(context)
    passages = if not pine? or prompt =~ "Retain both hops", do: [design, birth], else: [design]
    Transport.chat(facts: Enum.map(passages, &%{"source" => &1["id"], "text" => &1["text"]}))
  end

  defp answer(user, pine?, prompt) do
    case JSON.decode!(Offline.field(user, "facts")) do
      [design, birth] ->
        if pine? or prompt =~ "Connect both passages" do
          [_, country] = Regex.run(~r/born in (.+)\.$/, birth["text"])
          Transport.chat(answer: country, sources: [design["source"], birth["source"]])
        else
          Transport.chat(answer: "Argentina", sources: ["design"])
        end

      [_] ->
        Transport.chat(answer: "unknown", sources: ["design"])
    end
  end

  defp reflector(nil) do
    Transport.respond_with(fn body ->
      if Transport.prompt_text(body) =~ "Outputs: `facts`",
        do: Transport.chat(new_instruction: "Retain both hops: designer and birthplace."),
        else: Transport.chat(new_instruction: "Connect both passages and cite their IDs.")
    end)
  end

  defp reflector(instruction) do
    Transport.respond_with(fn _ -> Transport.chat(new_instruction: instruction) end)
  end
end
