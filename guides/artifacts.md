# Artifacts

An artifact is the part of a search result that you keep: the learned
parameters, a fingerprint of the contract they fit, and safe provenance. It
holds no code, no credentials, and no request options. The host application
saves it as JSON and later loads it into a fresh copy of its own target.

This guide tunes a ticket router offline, saves the result, and loads it
back. No model call runs.

## Tune a target

The router is one typed predictor. `:labeled_few_shot` picks demonstrations
from the training rows and makes no model calls. The host model configuration
carries a placeholder API key to show that it stays out of the artifact.

```elixir
defmodule TicketRouter do
  @moduledoc "Builds the support ticket router from trusted application code."

  def new(queues \\ ["billing", "bug", "account"]) do
    {:ok, predictor} =
      Tune.Predictor.new(
        signature: [
          instructions: "Route the support ticket to one queue.",
          inputs: [ticket: Zoi.string()],
          outputs: [queue: Zoi.enum(queues)]
        ]
      )

    predictor
  end
end

train = [
  %{id: "tr-1", input: %{ticket: "I was charged twice this month."}, expected: %{queue: "billing"}},
  %{id: "tr-2", input: %{ticket: "The export button does nothing."}, expected: %{queue: "bug"}},
  %{id: "tr-3", input: %{ticket: "Please change the email on my login."}, expected: %{queue: "account"}}
]

host_model = [
  model: "openai:gpt-4o-mini",
  adapter: Tune.Adapter.Chat,
  request_options: [api_key: "host-secret-placeholder", temperature: 0.0]
]

{:ok, result} =
  Tune.new(TicketRouter.new(), model: host_model)
  |> Tune.data(train: train)
  |> Tune.search(:labeled_few_shot, k: 2)
  |> Tune.limit(seed: 1)
  |> Tune.tune()
```

## Save the result as JSON

`Tune.dump/1` builds a `%Tune.Artifact{}` from the result.
`Tune.Artifact.encode/1` validates it and writes canonical JSON, so the same
artifact always encodes to the same bytes.

```elixir
{:ok, artifact} = Tune.dump(result)
{:ok, json} = Tune.Artifact.encode(artifact)

path = Path.join(System.tmp_dir!(), "ticket-router.json")
File.write!(path, json)

IO.inspect(json |> JSON.decode!() |> Map.keys())
IO.inspect(String.contains?(json, "host-secret-placeholder"))
```

```text
["parameters", "provenance", "target_fingerprint", "version"]
false
```

## Read the four fields

```elixir
entry = artifact.parameters["root"]

IO.inspect(artifact.version)
IO.inspect(Map.keys(entry))
IO.inspect(entry["demos"])
IO.inspect(artifact.provenance["optimizer"])
IO.inspect(artifact.provenance["models"])
```

```text
1
["demos", "fingerprint", "instructions", "kind"]
[
  %{
    "inputs" => %{"ticket" => "The export button does nothing."},
    "outputs" => %{"queue" => "bug"}
  },
  %{
    "inputs" => %{"ticket" => "Please change the email on my login."},
    "outputs" => %{"queue" => "account"}
  }
]
"Tune.Optimizers.LabeledFewShot"
%{
  "target" => %{
    "adapter" => "Tune.Adapter.Chat",
    "adapter_options" => %{},
    "model" => "openai:gpt-4o-mini"
  }
}
```

- `version` is the artifact format version. This release reads and writes `1`.
- `target_fingerprint` is a SHA-256 hash of the parameter contract: each
  parameter's name, kind, and field schemas.
- `parameters` holds the learned values by parameter name. A lone predictor
  uses the name `"root"`. A predictor entry has its `instructions`, its
  `demos`, and its own `fingerprint`. A `Tune.Parameter` entry has kind
  `"value"` and a `value`.
- `provenance` records how the values were learned: the strategy, its
  settings, the seed, dataset sizes and fingerprints, the best validation
  score, completion, the stop reason, and call and token totals.

Provenance describes models only by name, adapter, and adapter options.
Request options, API keys, functions, and response structs never enter it.

## Load into a fresh target

The host rebuilds the target from its own code, then applies the artifact
with `Tune.load/2`. The host supplies the model configuration again at run
time.

```elixir
{:ok, saved} = path |> File.read!() |> Tune.Artifact.decode()
{:ok, router} = Tune.load(saved, TicketRouter.new())

IO.inspect(Enum.map(router.demos, & &1.outputs))

{:ok, prepared} =
  router
  |> Tune.new(model: host_model)
  |> Tune.preview(%{ticket: "My card was declined."})

IO.inspect(Enum.map(prepared.context.messages, & &1.role))
```

```text
[%{"queue" => "bug"}, %{"queue" => "account"}]
[:system, :user, :assistant, :user, :assistant, :user]
```

The two demonstrations now appear as example turns before the new ticket.
The learned settings came from the artifact. The model, adapter, and
credentials came from the host. To serve requests, pass the loaded router to
`Tune.Runtime.run/3` with the same host configuration.

## A load that fails

`Tune.load/2` checks the whole contract before it changes anything. Here the
fresh router has only two queues, so its output schema differs from the one
the artifact was learned for.

```elixir
{:error, error} = Tune.load(saved, TicketRouter.new(["billing", "bug"]))
IO.puts(Exception.message(error))
```

```text
artifact was learned for a different program contract
```

The error is `Tune.Error.Invalid.Definition`. The load also fails when a
parameter is missing or extra, when a kind changes, or when a demonstration
does not fit its schema. A failed load never returns a partly updated target.

Instructions and field descriptions are not part of the fingerprint. A fresh
router with new instructions still loads, and the artifact's instructions
replace them:

```elixir
{:ok, reworded} = Tune.Predictor.put_instructions(TicketRouter.new(), "Pick a queue.")
{:ok, router} = Tune.load(saved, reworded)
IO.inspect(router.signature.instructions)
```

```text
"Route the support ticket to one queue."
```

## Decode untrusted JSON

`Tune.Artifact.decode/2` accepts only the four top-level fields and known
provenance fields. It creates no atoms from artifact text. It rejects input
over 5,000,000 bytes or over 1,000 parameters by default. Pass `:max_bytes`
and `:max_entries` to change the limits.

```elixir
tampered = json |> JSON.decode!() |> Map.put("module", "Elixir.System") |> JSON.encode!()
IO.inspect(match?({:error, _}, Tune.Artifact.decode(tampered)))
IO.inspect(match?({:error, _}, Tune.Artifact.decode(json, max_bytes: 100)))
```

```text
true
true
```

## Generic targets

A `:grid` or `:genetic` result over a map or struct saves only the fields
named in `Tune.vary/2`, with provenance kind `"generic"`. Loading needs a
fresh map or struct with the same field names and compatible JSON value
kinds. The [Quickstart](getting_started.md) saves and reloads a threshold
this way. Tensors, models, functions, and other opaque terms cannot become
artifact parameters.

## Keep secrets out of learned text

Tune leaves credentials and request options out. It does not scan learned
text.
Demonstrations, instructions, and lessons can copy training data into the
artifact. Use training rows that are safe to store, and review learned text
before you ship it.

## Next steps

- [Programs](programs.md) shows how a program declares the parameters an artifact saves.
- [Search API](optimizers.md) lists the strategies that produce these results.
- [Deploy a Router](integration/deploy-a-router.livemd) loads an artifact into a running OTP service and keeps the last valid program when a load fails.
