defmodule Tune.Contracts.ArtifactTest do
  use ExUnit.Case, async: true

  alias Tune
  alias Tune.Adapter
  alias Tune.Artifact
  alias Tune.Error
  alias Tune.Examples.GroundedQA
  alias Tune.ModelConfig
  alias Tune.Optimizers.BootstrapFewShot
  alias Tune.Parameter
  alias Tune.Predictor
  alias Tune.TestSupport.QAWorld
  alias Tune.TestSupport.Transport

  @secret "artifact-secret-key"

  defp config(stub),
    do: [
      model: Transport.model(),
      adapter: Adapter.Chat,
      request_options: Transport.request_options(stub) ++ [api_key: @secret]
    ]

  setup_all do
    {:ok, model} =
      ModelConfig.new(
        model: Transport.model(),
        adapter: Adapter.JSON,
        adapter_options: [mode: :text],
        request_options: [api_key: @secret]
      )

    %{model: model}
  end

  defp optimized do
    rows =
      QAWorld.rows([{"What is Alpha?", "alpha", "first"}, {"What is Beta?", "beta", "second"}])

    {:ok, program, report} =
      Tune.TestSupport.Search.run(GroundedQA.new(),
        optimizer: {BootstrapFewShot, accept_score: 1.0, max_bootstrapped_demos: 2},
        trainset: rows,
        metric: &QAWorld.metric/2,
        model: config(QAWorld.stub()),
        teacher: config(QAWorld.stub()),
        max_model_calls: 10
      )

    {:ok, lessons} = Parameter.put_value(program.lessons, ["Quote the passage id."])
    {:ok, program} = Tune.Program.replace_parameters(program, %{"lessons" => lessons})
    {program, report}
  end

  test "an optimized QA program reloads into fresh code with the same values and provenance", %{
    model: model
  } do
    {program, report} = optimized()
    provenance = Artifact.provenance(source: "test", report: report, models: [target: model])

    assert {:ok, artifact} = Artifact.dump(program, provenance: provenance)
    assert {:ok, json} = Artifact.encode(artifact)
    assert {:ok, decoded} = Artifact.decode(json)
    assert {:ok, loaded} = Artifact.apply(decoded, GroundedQA.new())

    assert loaded.extract.demos == program.extract.demos
    assert loaded.answer.demos == program.answer.demos
    assert loaded.answer.signature.instructions == program.answer.signature.instructions
    assert loaded.lessons.value == ["Quote the passage id."]

    assert decoded.provenance["optimizer"] == "Tune.Optimizers.BootstrapFewShot"
    assert decoded.provenance["calls"] == %{"teacher" => 4}
    assert decoded.provenance["models"]["target"]["model"] == "openai:gpt-4-turbo"
    assert decoded.provenance["datasets"]["train"] == 2
    assert is_binary(decoded.provenance["datasets"]["train_fingerprint"])

    refute json =~ @secret
    refute json =~ "api_key"
    refute json =~ "req_http_options"
  end

  test "encoding is canonical and stable" do
    {program, _report} = optimized()
    {:ok, artifact} = Artifact.dump(program)
    {:ok, first} = Artifact.encode(artifact)
    {:ok, decoded} = Artifact.decode(JSON.encode!(wire(artifact)))
    {:ok, second} = Artifact.encode(decoded)
    assert first == second
  end

  describe "fingerprints" do
    setup do
      {:ok, base} =
        Predictor.new(
          signature: [inputs: [q: Zoi.string(description: "a")], outputs: [a: Zoi.string()]]
        )

      %{base: base}
    end

    test "ignore instructions and field prose", %{base: base} do
      {:ok, instructed} = Predictor.put_instructions(base, "New instructions.")

      {:ok, described} =
        Predictor.new(
          signature: [
            inputs: [q: Zoi.string(description: "different")],
            outputs: [a: Zoi.string()]
          ]
        )

      assert Artifact.fingerprint(base) == Artifact.fingerprint(instructed)
      assert Artifact.fingerprint(base) == Artifact.fingerprint(described)
    end

    test "change with field order, names, or schemas", %{base: base} do
      {:ok, two} =
        Predictor.new(
          signature: [inputs: [q: Zoi.string(), r: Zoi.string()], outputs: [a: Zoi.string()]]
        )

      {:ok, swapped} =
        Predictor.new(
          signature: [inputs: [r: Zoi.string(), q: Zoi.string()], outputs: [a: Zoi.string()]]
        )

      {:ok, typed} =
        Predictor.new(signature: [inputs: [q: Zoi.integer()], outputs: [a: Zoi.string()]])

      {:ok, renamed} =
        Predictor.new(signature: [inputs: [question: Zoi.string()], outputs: [a: Zoi.string()]])

      fingerprints = Enum.map([base, two, swapped, typed, renamed], &Artifact.fingerprint/1)
      assert length(Enum.uniq(fingerprints)) == 5
    end
  end

  describe "mismatches apply nothing" do
    setup do
      {program, _report} = optimized()
      {:ok, artifact} = Artifact.dump(program)
      %{artifact: artifact}
    end

    test "a missing or extra entry", %{artifact: artifact} do
      missing = %{artifact | parameters: Map.delete(artifact.parameters, "lessons")}

      assert {:error, %Error.Invalid.Definition{}} =
               Artifact.apply(missing, GroundedQA.new())

      extra =
        %{
          artifact
          | parameters: Map.put(artifact.parameters, "other", artifact.parameters["lessons"])
        }

      assert {:error, %Error.Invalid.Definition{}} = Artifact.apply(extra, GroundedQA.new())
    end

    test "a kind change", %{artifact: artifact} do
      swapped =
        %{
          artifact
          | parameters: Map.put(artifact.parameters, "lessons", artifact.parameters["answer"])
        }

      assert {:error, %Error.Invalid.Definition{message: message}} =
               Artifact.apply(swapped, GroundedQA.new())

      assert message =~ "different kind"
    end

    test "a schema change in code", %{artifact: artifact} do
      program = GroundedQA.new()
      {:ok, changed} = Parameter.new(schema: Zoi.array(Zoi.integer()), value: [])
      program = %{program | lessons: changed}

      assert {:error, %Error.Invalid.Definition{message: message}} =
               Artifact.apply(artifact, program)

      assert message =~ "different program contract"
    end

    test "an invalid demonstration or value", %{artifact: artifact} do
      bad_demo =
        update_in(artifact.parameters["answer"]["demos"], fn [demo | rest] ->
          [put_in(demo["outputs"]["sources"], "not a list") | rest]
        end)

      fresh = GroundedQA.new()
      assert {:error, %Error.Invalid.Definition{}} = Artifact.apply(bad_demo, fresh)
      assert fresh == GroundedQA.new()

      bad_value = put_in(artifact.parameters["lessons"]["value"], [1])
      assert {:error, %Error.Invalid.Definition{}} = Artifact.apply(bad_value, GroundedQA.new())
    end
  end

  describe "decode" do
    setup do
      {program, _report} = optimized()
      {:ok, artifact} = Artifact.dump(program)
      {:ok, json} = Artifact.encode(artifact)
      %{artifact: artifact, json: json}
    end

    test "rejects unknown versions, formats, fields, and kinds", %{artifact: artifact} do
      artifact = wire(artifact)

      cases = [
        Map.put(artifact, "version", 2),
        Map.put(artifact, "format", "other"),
        Map.put(artifact, "module", "Elixir.System"),
        put_in(artifact["parameters"]["lessons"]["kind"], "function"),
        put_in(artifact["parameters"]["lessons"]["code"], "System.halt()"),
        Map.put(artifact, "provenance", %{"api_key" => "x"})
      ]

      for data <- cases do
        assert {:error, %Error.Invalid.Definition{}} = Artifact.decode(JSON.encode!(data))
      end
    end

    test "enforces byte and entry limits", %{json: json} do
      assert {:error, %Error.Invalid.Definition{}} = Artifact.decode(json, max_bytes: 10)
      assert {:error, %Error.Invalid.Definition{}} = Artifact.decode(json, max_entries: 1)
      assert {:ok, _} = Artifact.decode(json)
    end

    test "creates no atoms from artifact data", %{artifact: artifact} do
      key = "never_seen_atom_#{System.unique_integer([:positive])}"

      data =
        put_in(wire(artifact)["parameters"][key], %{
          "kind" => "value",
          "fingerprint" => "x",
          "value" => %{key => 1}
        })

      assert {:ok, decoded} = Artifact.decode(JSON.encode!(data))
      assert {:error, _} = Artifact.apply(decoded, GroundedQA.new())
      assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    end
  end

  test "dump rejects provenance that is not plain allowlisted data" do
    assert {:error, %Error.Invalid.Definition{}} =
             Artifact.dump(GroundedQA.new(), provenance: %{"source" => fn -> :x end})

    assert {:error, %Error.Invalid.Definition{}} =
             Artifact.dump(GroundedQA.new(), provenance: %{"request_options" => []})
  end

  defp wire(artifact) do
    %{
      "version" => artifact.version,
      "target_fingerprint" => artifact.target_fingerprint,
      "parameters" => artifact.parameters,
      "provenance" => artifact.provenance
    }
  end
end
