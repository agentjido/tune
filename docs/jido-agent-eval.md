# Compare two Jido agent traces

The host runs Jido v3 and gives Tune ordinary rows. Run the same request with
two inference scripts, start from fresh agent state each time, and pair the
two evaluations by case ID. Install Jido and Tune in the host project or
Livebook. Tune itself has no Jido dependency.

Load the modules from **The Agent under test** and **Build a scripted client**
in the Jido v3 testing notebook. Use the Jido revision in the link to run the
same fixture. The example uses its in-memory ticket lookup.
The baseline claims the ticket is open without a lookup. The challenger looks up
the ticket and gives the same answer. Run this test in the host where those
fixtures are loaded. In Livebook, start ExUnit with `autorun: false` before this
cell and call `ExUnit.run()` after it.
[Jido v3 testing notebook](https://github.com/agentjido/jido/blob/108852af90af7ffb938080a6d91afc542223f8d8/guides/ai/testing-ai-agents.livemd)

```elixir
defmodule CompareAgentTracesTest do
  use ExUnit.Case, async: false

  alias TestingAIGuide.{ScriptedModel, SupportAgent}

  test "the same answer can conceal a missing lookup" do
    baseline = capture(["Ticket T-1 is open."], "baseline")

    challenger =
      capture(
        [{:tool, "call-1", "lookup_ticket", %{ticket_id: "T-1"}}, "Ticket T-1 is open."],
        "challenger"
      )

    {id, before_scores} = evaluate(baseline)
    {^id, after_scores} = evaluate(challenger)

    assert before_scores == %{answer: 1, lookup: 0}
    assert after_scores == %{answer: 1, lookup: 1}
  end

  defp capture(script, agent_id) do
    :ok = ScriptedModel.start_script(script)
    agent = SupportAgent.instantiate!(id: agent_id)
    input = "Is T-1 open?"

    {:ok, _agent, [%Jido.Agent.Directive.Reply{signal: reply}]} =
      SupportAgent.cmd(agent, SupportAgent.request_signal!(%{input: input}),
        context: %{jido_ai_inference_client: ScriptedModel}
      )

    assert ScriptedModel.unused_steps() == []
    :ok = stop_supervised(ScriptedModel)

    tool_attempts =
      Enum.map(reply.data.tool_attempts, &Map.take(&1, [:tool_name, :input, :status]))

    %{
      id: "lookup-t1",
      input: %{question: input},
      expected: %{answer: "Ticket T-1 is open.", ticket_id: "T-1"},
      output: %{answer: reply.data.output, tool_attempts: tool_attempts}
    }
  end

  defp evaluate(trace) do
    study =
      Tune.replay([trace])
      |> Tune.score(:answer, fn row, output ->
        if output.answer == row.expected.answer, do: 1, else: 0
      end)
      |> Tune.score(:lookup, fn row, output ->
        case output.tool_attempts do
          [%{tool_name: "lookup_ticket", input: %{"ticket_id" => id}, status: :ok}]
          when id == row.expected.ticket_id ->
            1

          _ ->
            0
        end
      end)

    {:ok, %{observations: [observation]}} = Tune.evaluate(study)
    {observation.id, observation.scores}
  end
end
```

The fixture uses a single case, so a pinned ID is sufficient for the join. For
a suite, validate unique IDs and report missing rows. Keep the dataset, scorer
versions, tool fixtures, and starting state fixed across the two runs. Save
only the tool evidence the scores need. A real host can redact and reduce the
tool records before it writes the rows to disk.

`Tune.replay/2` scores each saved trace independently. `Tune.compare/3` runs a
target and a search result or artifact on the same cases. For saved runs, pair
the two reports in the host as above.
[Replay JSONL](../guides/examples/replay-jsonl.livemd) ·
[Gate a Release](../guides/examples/gate-a-release.livemd)
