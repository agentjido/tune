# Artifacts

`Tune.dump/1` creates one `%Tune.Artifact{}` from a tuning result. The artifact
contains learned values and safe run provenance. It does not contain code,
credentials, request options, functions, response structs, tensors, or models.

```elixir
{:ok, artifact} = Tune.dump(result)
{:ok, json} = Tune.Artifact.encode(artifact)
File.write!("tune.json", json)

{:ok, decoded} = File.read!("tune.json") |> Tune.Artifact.decode()
{:ok, updated_program} = Tune.load(decoded, fresh_program)
```

Here, `result` is a completed tuning result and `fresh_program` is the
original program from your application. For a runnable example with a plain
Elixir target, see [save and reload a setting](getting_started.md#save-and-reload-the-selected-setting).

The application supplies fresh code and runtime model configuration. Loading
an artifact validates the full contract before it changes the target. A failed
load returns an error and does not partly update the target.

## Artifact shape

```json
{
  "version": 1,
  "target_fingerprint": "sha256-value",
  "parameters": {},
  "provenance": {}
}
```

`Tune.Artifact.decode/1` accepts only these four fields and enforces a fixed
size limit. It creates no atoms from artifact text. Zoi validates the data as
JSON-compatible values.

## Structured programs

For a Tune program, `parameters` contains the program's named predictors and
declared values. Predictor fingerprints cover ordered field names and JSON
schemas. Instructions and schema prose do not change the fingerprint.

Loading requires the same parameter names, kinds, and field contracts. The
loaded artifact can change instructions, demonstrations, and declared
JSON-compatible values. It cannot change application code or a predictor's
input and output fields.

## Generic targets

For a generic map or struct, `parameters` contains only the values declared by
`Tune.vary/2`. Loading requires the same names and compatible JSON value kinds
in a fresh target.

Nx tensors, Axon models, functions, processes, ports, references, and other
opaque terms can pass through runners and result metadata. They cannot become
learned artifact parameters.

## Provenance

Provenance can record the strategy, completion state, stop reason, score names,
safe model descriptions, data fingerprints, call totals, and usage totals.
Runtime options and credentials stay in the application.

Demonstrations and learned text can contain application data. Tune does not
remove secrets from that content. The application must control the data that it
uses for training and artifacts.
