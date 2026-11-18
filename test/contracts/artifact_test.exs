defmodule Tune.Contracts.ArtifactTest do
  use ExUnit.Case, async: true

  alias Tune
  alias Tune.Adapter
  alias Tune.Artifact
  alias Tune.Artifact.Program
  alias Tune.Error
  alias Tune.Examples.Support.GroundedQA
  alias Tune.Examples.Support.QAWorld
  alias Tune.Examples.Support.Transport
  alias Tune.Optimizers.BootstrapFewShot
  alias Tune.Parameter
  alias Tune.Predictor

  @secret "artifact-secret-key"

  defp config(stub),
    do: [
      model: Transport.model(),
      adapter: Adapter.Chat,
      request_options: Transport.request_options(stub) ++ [api_key: @secret]
    ]

  defp optimized do
    rows =
      QAWorld.rows([{"What is Alpha?", "alpha", "first"}, {"What is Beta?", "beta", "second"}])

    {:ok, program, report} =
      Tune.TestSupport.Search.run(GroundedQA.new(),
        search: {BootstrapFewShot, accept_score: 1.0, max_bootstrapped_demos: 2},
        train: rows,
        metric: &QAWorld.metric/2,
        model: config(QAWorld.stub()),
        teacher: config(QAWorld.stub()),
        model_calls: 10
      )

    {:ok, lessons} = Parameter.put_value(program.lessons, ["Quote the passage id."])
    {:ok, program} = Tune.Program.replace_parameters(program, %{"lessons" => lessons})
    %{report | value: program}
  end

  test "an optimized QA program reloads into fresh code with the same values and provenance" do
    report = optimized()
    program = report.value

    assert {:ok, artifact} = Tune.dump(report)
    assert {:ok, json} = Artifact.encode(artifact)
    assert {:ok, decoded} = Artifact.decode(json)
    assert {:ok, loaded} = Tune.load(decoded, GroundedQA.new())

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
    {:ok, artifact} = Tune.dump(optimized())
    {:ok, first} = Artifact.encode(artifact)
    {:ok, decoded} = Artifact.decode(JSON.encode!(wire(artifact)))
    {:ok, second} = Artifact.encode(decoded)
    assert first == second
  end

  test "loads a version 1 generic artifact and validates the target contract" do
    json = ~S"""
    {
      "version": 1,
      "target_fingerprint": "6996dda8394e7c86f4d4ea07fbd53ef52c839a20eb413907f99d3b416988769c",
      "parameters": {"batch_size": 8},
      "provenance": {"kind": "generic"}
    }
    """

    assert {:ok, artifact} = Artifact.decode(json)
    assert {:ok, %{batch_size: 8}} = Tune.load(artifact, %{batch_size: 1})
    assert {:ok, encoded} = Artifact.encode(artifact)
    assert JSON.decode!(json) == JSON.decode!(encoded)

    assert {:error, %Error.Invalid.Definition{}} =
             Tune.load(artifact, %{:batch_size => 1, "batch_size" => 2})

    assert {:ok, %{{:runtime, :state} => :live, batch_size: 8}} =
             Tune.load(artifact, %{:batch_size => 1, {:runtime, :state} => :live})

    malformed = put_in(artifact.parameters["batch_size"], "eight")
    assert {:error, %Error.Invalid.Definition{}} = Tune.load(malformed, %{batch_size: 1})
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

      assert Program.fingerprint(base) == Program.fingerprint(instructed)
      assert Program.fingerprint(base) == Program.fingerprint(described)
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

      fingerprints = Enum.map([base, two, swapped, typed, renamed], &Program.fingerprint/1)
      assert length(Enum.uniq(fingerprints)) == 5
    end
  end

  describe "mismatches apply nothing" do
    setup do
      {:ok, artifact} = Tune.dump(optimized())
      %{artifact: artifact}
    end

    test "a missing or extra entry", %{artifact: artifact} do
      missing = %{artifact | parameters: Map.delete(artifact.parameters, "lessons")}

      assert {:error, %Error.Invalid.Definition{}} =
               Tune.load(missing, GroundedQA.new())

      extra =
        %{
          artifact
          | parameters: Map.put(artifact.parameters, "other", artifact.parameters["lessons"])
        }

      assert {:error, %Error.Invalid.Definition{}} = Tune.load(extra, GroundedQA.new())
    end

    test "a kind change", %{artifact: artifact} do
      swapped =
        %{
          artifact
          | parameters: Map.put(artifact.parameters, "lessons", artifact.parameters["answer"])
        }

      assert {:error, %Error.Invalid.Definition{message: message}} =
               Tune.load(swapped, GroundedQA.new())

      assert message =~ "different kind"
    end

    test "a schema change in code", %{artifact: artifact} do
      program = GroundedQA.new()
      {:ok, changed} = Parameter.new(schema: Zoi.array(Zoi.integer()), value: [])
      program = %{program | lessons: changed}

      assert {:error, %Error.Invalid.Definition{message: message}} =
               Tune.load(artifact, program)

      assert message =~ "different program contract"
    end

    test "an invalid demonstration or value", %{artifact: artifact} do
      bad_demo =
        update_in(artifact.parameters["answer"]["demos"], fn [demo | rest] ->
          [put_in(demo["outputs"]["sources"], "not a list") | rest]
        end)

      fresh = GroundedQA.new()
      assert {:error, %Error.Invalid.Definition{}} = Tune.load(bad_demo, fresh)
      assert fresh == GroundedQA.new()

      bad_value = put_in(artifact.parameters["lessons"]["value"], [1])
      assert {:error, %Error.Invalid.Definition{}} = Tune.load(bad_value, GroundedQA.new())
    end
  end

  describe "decode" do
    setup do
      {:ok, artifact} = Tune.dump(optimized())
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
      assert {:error, _} = Tune.load(decoded, GroundedQA.new())
      assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    end
  end

  test "an artifact rejects provenance outside its data contract" do
    {:ok, artifact} = Tune.dump(optimized())
    attrs = Map.from_struct(artifact)

    assert {:error, %Error.Invalid.Definition{}} =
             Artifact.new(put_in(attrs.provenance["source"], fn -> :x end))

    assert {:error, %Error.Invalid.Definition{}} =
             Artifact.new(put_in(attrs.provenance["request_options"], []))
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
