# Parameter artifacts

New artifacts use the format identifier `tune.parameters`, version 1. Tune also
accepts version 1 artifacts with the former `req_llm_program.parameters`
identifier, including direct `apply/2` calls. Decoding and encoding use the new
identifier. Parameter payloads and schema fingerprints are unchanged. Old
readers do not accept the new identifier. Provenance from an old artifact can
retain old module names; these strings are descriptive and never load code.

Learned parameters are exchanged as versioned JSON data. Code, model
configuration, and credentials stay in the application.

```elixir
provenance = Tune.Parameters.provenance(source: "nightly", report: report, models: [target: model])
{:ok, artifact} = Tune.Parameters.dump(optimized, provenance: provenance)
{:ok, json} = Tune.Parameters.encode(artifact)
File.write!("qa_params.json", json)

{:ok, decoded} = Tune.Parameters.decode(File.read!("qa_params.json"))
{:ok, program} = Tune.Parameters.apply(MyApp.QA.new(), decoded)
```

## Format (version 1)

```json
{
  "format": "tune.parameters",
  "version": 1,
  "entries": {
    "answer": {"kind": "predictor", "fingerprint": "…", "instructions": "…", "demos": [{"inputs": {}, "outputs": {}}]},
    "lessons": {"kind": "value", "fingerprint": "…", "value": ["…"]}
  },
  "provenance": {"source": "…", "models": {}, "optimizer": "…", "settings": {}, "seed": 0,
                 "datasets": {}, "best": {}, "complete": true, "stop_reason": "completed",
                 "calls": {}, "usage": {}}
}
```

- Predictor fingerprints cover ordered field names and JSON schemas; value
  fingerprints cover the schema. Instructions, values, and schema prose
  (`description`, `title`, `examples`) are excluded. SHA-256 over canonical
  JSON with sorted keys.
- `decode/2` rejects unknown formats, versions, fields, and kinds, and
  enforces byte and entry limits. No atoms are created and no code is loaded.
- `apply/2` requires exactly the program's declared names, the same kinds and
  fingerprints, and valid values, then applies everything at once. A failed
  load changes nothing.
- Provenance is an allowlist of descriptive data. It never contains request
  options, credentials, functions, processes, or responses, and it never
  selects models.
- Demonstrations and lessons can contain application text. There is no
  content-based secret removal.
- A reloaded `Tune.KNN` program still needs a teacher configuration
  and an explicit `:max_model_calls` at run time; its vectorizer is code and
  is not saved.
