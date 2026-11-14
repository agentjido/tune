defmodule Tune.Contracts.HostBoundaryTest do
  use ExUnit.Case, async: true

  alias Tune.Adapter
  alias Tune.Error
  alias Tune.ModelConfig
  alias Tune.Predictor
  alias Tune.Prepared
  alias Tune.TestSupport.Transport

  @secret "host-secret-key-123"

  setup do
    {:ok, predictor} =
      Predictor.new(
        signature: [inputs: [question: Zoi.string()], outputs: [answer: Zoi.string()]]
      )

    {:ok, config} =
      ModelConfig.new(
        model: Transport.model(),
        adapter: Adapter.Chat,
        request_options: [api_key: @secret, temperature: 0.0]
      )

    %{predictor: predictor, config: config}
  end

  defmodule Host do
    def execute(%Prepared{} = prepared, :allow, request_options) do
      send(self(), :host_executed)

      ReqLLM.generate_text(
        Transport.model(),
        prepared.context,
        [output: prepared.output] ++ request_options
      )
    end

    def execute(%Prepared{}, :deny, _request_options), do: {:error, :denied_by_host}
  end

  test "prepare is pure and holds no credentials or request options", ctx do
    assert {:ok, %Prepared{} = prepared} =
             Predictor.prepare(ctx.predictor, %{question: "Why?"}, ctx.config)

    refute inspect(prepared, limit: :infinity, printable_limit: :infinity) =~ @secret
    refute inspect(prepared, limit: :infinity) =~ "temperature"
    assert prepared.inputs == %{"question" => "Why?"}
  end

  test "a host executes a prepared request once and finish makes no model request", ctx do
    stub = Transport.script([{:text, "[[ ## answer ## ]]\nBecause.\n\n[[ ## completed ## ]]"}])
    {:ok, prepared} = Predictor.prepare(ctx.predictor, %{question: "Why?"}, ctx.config)

    assert {:ok, response} = Host.execute(prepared, :allow, Transport.request_options(stub))
    assert_received :host_executed
    assert [_one] = Transport.requests(stub)

    assert {:ok, step} = Predictor.finish(prepared, response)
    assert step.outputs == %{"answer" => "Because."}
    assert Transport.requests(stub) == []
  end

  test "host denial cannot produce a step", ctx do
    {:ok, prepared} = Predictor.prepare(ctx.predictor, %{question: "Why?"}, ctx.config)
    assert {:error, :denied_by_host} = Host.execute(prepared, :deny, [])
  end

  test "finish validates an offline response without transport", ctx do
    {:ok, prepared} = Predictor.prepare(ctx.predictor, %{question: "Why?"}, ctx.config)

    ok = response("[[ ## answer ## ]]\nYes.", :stop)
    assert {:ok, %{outputs: %{"answer" => "Yes."}}} = Predictor.finish(prepared, ok)

    assert {:error, %Error.Output.Rejected{reason: :finish_reason}} =
             Predictor.finish(prepared, response("[[ ## answer ## ]]\nYe", :length))

    assert {:error, %Error.Output.Rejected{reason: :response_error}} =
             Predictor.finish(prepared, %{ok | error: %RuntimeError{message: "stream broke"}})

    assert {:error, %Error.Output.Rejected{reason: :finish_reason}} =
             Predictor.finish(prepared, %{ok | finish_reason: nil})
  end

  defp response(text, finish_reason) do
    %ReqLLM.Response{
      id: "offline",
      model: "gpt-4-turbo",
      context: ReqLLM.Context.new(),
      message: ReqLLM.Context.assistant(text),
      finish_reason: finish_reason
    }
  end
end
