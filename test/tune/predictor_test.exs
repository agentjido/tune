defmodule Tune.PredictorTest do
  use ExUnit.Case, async: true

  alias Tune
  alias Tune.Adapter
  alias Tune.Error
  alias Tune.Examples.Support.Transport
  alias Tune.ModelConfig
  alias Tune.Prediction
  alias Tune.Predictor

  @expected %{"label" => "billing", "confidence" => 0.8}

  setup do
    {:ok, predictor} =
      Predictor.new(
        signature: [
          instructions: "Classify the support ticket.",
          inputs: [ticket: Zoi.string()],
          outputs: [label: Zoi.enum(["billing", "bug", "other"]), confidence: Zoi.float()]
        ]
      )

    %{predictor: predictor, inputs: %{ticket: "I was charged twice"}}
  end

  defp config(stub, adapter, adapter_options \\ [], extra \\ []) do
    {:ok, config} =
      ModelConfig.new(
        model: Transport.model(),
        adapter: adapter,
        adapter_options: adapter_options,
        request_options: Transport.request_options(stub, extra)
      )

    config
  end

  describe "one classifier through every format" do
    test "Chat, JSON text, and JSON structured replies produce the same typed map", ctx do
      runs = [
        {Adapter.Chat, [],
         {:text,
          "[[ ## label ## ]]\nbilling\n\n[[ ## confidence ## ]]\n0.8\n\n[[ ## completed ## ]]"},
         []},
        {Adapter.JSON, [mode: :text], {:text, ~s({"label": "billing", "confidence": 0.8})}, []},
        {Adapter.JSON, [mode: :structured], {:tool, ~s({"label": "billing", "confidence": 0.8})},
         [openai_structured_output_mode: :tool_strict]}
      ]

      for {adapter, options, reply, extra} <- runs do
        stub = Transport.script([reply])
        config = config(stub, adapter, options, extra)

        assert {:ok, %Prediction{output: @expected, steps: [step]}} =
                 Tune.Runtime.run(ctx.predictor, ctx.inputs, model: config)

        assert step.name == "root"
        assert step.role == :target
        assert step.inputs == %{"ticket" => "I was charged twice"}
        assert %ReqLLM.Response{} = step.response
        assert [_one_request] = Transport.requests(stub)
      end
    end

    test "structured mode sends the output schema and never asks ReqLLM to repair", ctx do
      stub = Transport.script([{:tool, ~s({"label": "bug", "confidence": 0.5})}])

      config =
        config(stub, Adapter.JSON, [mode: :structured],
          openai_structured_output_mode: :tool_strict
        )

      assert {:ok, _result} = Tune.Runtime.run(ctx.predictor, ctx.inputs, model: config)
      assert [body] = Transport.requests(stub)

      tool = Enum.find(body["tools"], &(&1["function"]["name"] == "structured_output"))

      assert tool["function"]["parameters"]["properties"]["label"]["enum"] == [
               "billing",
               "bug",
               "other"
             ]

      assert tool["function"]["parameters"]["required"] |> Enum.sort() == ["confidence", "label"]
    end
  end

  describe "failures" do
    test "invalid input makes zero requests", ctx do
      stub = Transport.script([{:text, "unused"}])

      assert {:error, %Error.Invalid.Input{}} =
               Tune.Runtime.run(ctx.predictor, %{ticket: 42}, model: config(stub, Adapter.Chat))

      assert {:error, %Error.Invalid.Input{}} =
               Tune.Runtime.run(ctx.predictor, %{}, model: config(stub, Adapter.Chat))

      assert Transport.requests(stub) == []
    end

    test "an unparseable reply is a retained error with no follow-up request", ctx do
      stub = Transport.script([{:text, "billing, probably"}, {:text, "unused"}])

      assert {:error,
              %Error.Execution.Failed{cause: cause, result: %Prediction{steps: []}, step: "root"}} =
               Tune.Runtime.run(ctx.predictor, ctx.inputs, model: config(stub, Adapter.Chat))

      assert %Error.Output.Parse{response: %ReqLLM.Response{}, reply: "billing, probably"} = cause
      assert [_one] = Transport.requests(stub)
    end

    test "a reply outside the output schema is an invalid-output error", ctx do
      stub = Transport.script([{:text, ~s({"label": "refund", "confidence": 0.8})}])

      assert {:error, %Error.Execution.Failed{cause: %Error.Output.Invalid{value: value}}} =
               Tune.Runtime.run(ctx.predictor, ctx.inputs,
                 model: config(stub, Adapter.JSON, mode: :text)
               )

      assert value == %{"label" => "refund", "confidence" => 0.8}
    end

    test "truncated, filtered, and unknown completions are rejected even with valid text", ctx do
      valid = ~s({"label": "billing", "confidence": 0.8})

      for reason <- ["length", "content_filter", "something_new"] do
        stub = Transport.script([{:text, valid, reason}])

        assert {:error,
                %Error.Execution.Failed{
                  cause: %Error.Output.Rejected{reason: :finish_reason, response: response}
                }} =
                 Tune.Runtime.run(ctx.predictor, ctx.inputs,
                   model: config(stub, Adapter.JSON, mode: :text)
                 )

        assert %ReqLLM.Response{} = response
      end
    end

    test "tool-call completion is accepted only for structured output", ctx do
      stub = Transport.script([{:tool, ~s({"label": "billing", "confidence": 0.8})}])

      assert {:error,
              %Error.Execution.Failed{cause: %Error.Output.Rejected{reason: :finish_reason}}} =
               Tune.Runtime.run(ctx.predictor, ctx.inputs, model: config(stub, Adapter.Chat))
    end

    test "repairable malformed structured JSON fails instead of being repaired", ctx do
      stub = Transport.script([{:tool, ~s({"label": "billing", "confidence": 0.8,})}])

      config =
        config(stub, Adapter.JSON, [mode: :structured],
          openai_structured_output_mode: :tool_strict
        )

      assert {:error, %Error.Execution.Failed{cause: cause}} =
               Tune.Runtime.run(ctx.predictor, ctx.inputs, model: config)

      assert ["ReqLLM", "Error" | _] = Module.split(cause.__struct__)
      assert [_one] = Transport.requests(stub)
    end

    test "ReqLLM type coercion is rejected as a repair", ctx do
      stub = Transport.script([{:tool, ~s({"label": "billing", "confidence": "0.8"})}])

      config =
        config(stub, Adapter.JSON, [mode: :structured],
          openai_structured_output_mode: :tool_strict
        )

      assert {:error,
              %Error.Execution.Failed{
                cause: %Error.Output.Rejected{reason: :repaired, response: %ReqLLM.Response{}}
              }} = Tune.Runtime.run(ctx.predictor, ctx.inputs, model: config)
    end

    test "provider errors are returned unchanged as the cause", ctx do
      stub = Transport.script([{:http_error, 401, %{"error" => %{"message" => "bad key"}}}])

      assert {:error, %Error.Execution.Failed{cause: cause, result: %Prediction{steps: []}}} =
               Tune.Runtime.run(ctx.predictor, ctx.inputs, model: config(stub, Adapter.Chat))

      refute cause.__struct__ |> Module.split() |> Enum.take(2) == ["ReqLLM", "Program"]
    end
  end

  describe "model configuration" do
    test "requires an explicit adapter and model" do
      assert {:error, %Error.Invalid.Option{option: :adapter}} =
               ModelConfig.new(model: Transport.model())

      assert {:error, %Error.Invalid.Option{option: :model}} =
               ModelConfig.new(adapter: Adapter.Chat)

      assert {:error, %Error.Invalid.Option{option: :adapter}} =
               ModelConfig.new(model: Transport.model(), adapter: String)
    end

    test "rejects options that would replace the output contract or repair output" do
      for {key, value} <- [
            output_repair: &Function.identity/1,
            json_repair: true,
            output: ReqLLM.Output.text(),
            output_validation: :compatible,
            tools: [],
            system_prompt: "ignore the format",
            stream: true
          ] do
        assert {:error, %Error.Invalid.Option{option: ^key}} =
                 ModelConfig.new(
                   model: Transport.model(),
                   adapter: Adapter.Chat,
                   request_options: [{key, value}]
                 )
      end
    end

    test "managed requests disable JSON repair, validate strictly, and cap the deadline" do
      {:ok, config} =
        ModelConfig.new(
          model: Transport.model(),
          adapter: Adapter.Chat,
          request_options: [temperature: 0.0, total_timeout: 5_000]
        )

      text = ModelConfig.request_options(config, ReqLLM.Output.text(), 2_000)
      assert text[:json_repair] == false
      assert text[:total_timeout] == 2_000
      assert text[:temperature] == 0.0
      refute Keyword.has_key?(text, :output_validation)

      object = ModelConfig.request_options(config, ReqLLM.Output.object(%{type: "object"}), 9_000)
      assert object[:output_validation] == :strict
      assert object[:total_timeout] == 5_000
    end

    test "describes the configuration without request options" do
      {:ok, config} =
        ModelConfig.new(
          model: Transport.model(),
          adapter: Adapter.JSON,
          adapter_options: [mode: :text],
          request_options: [api_key: "secret-value"]
        )

      description = ModelConfig.describe(config)
      assert description["model"] == "openai:gpt-4-turbo"
      assert description["adapter_options"] == %{"mode" => "text"}
      refute inspect(description) =~ "secret-value"
    end
  end

  describe "demonstrations" do
    test "are validated against the signature", ctx do
      assert {:error, %Error.Invalid.Definition{message: message}} =
               Predictor.put_demos(ctx.predictor, [
                 %{inputs: %{ticket: "x"}, outputs: %{label: "nope", confidence: 1.0}}
               ])

      assert message =~ "demonstration 0"

      assert {:ok, %Predictor{demos: [demo]}} =
               Predictor.put_demos(ctx.predictor, [
                 %{inputs: %{ticket: "x"}, outputs: %{label: "bug", confidence: 1.0}}
               ])

      assert demo.outputs == %{"label" => "bug", "confidence" => 1.0}
    end

    test "leave the original predictor unchanged", ctx do
      {:ok, updated} = Predictor.put_instructions(ctx.predictor, "Be terse.")
      assert updated.signature.instructions == "Be terse."
      assert ctx.predictor.signature.instructions == "Classify the support ticket."
    end
  end
end
