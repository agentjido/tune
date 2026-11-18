defmodule Tune.Contracts.InputValidationTest do
  use ExUnit.Case, async: true

  alias Tune.Error
  alias Tune.Examples.Support.Transport
  alias Tune.ModelConfig

  test "rejects invalid public options and preserves Tune's semantic checks" do
    study = Tune.new(1, run: fn _, input -> input end)

    assert_raise ArgumentError, ~r/concurrency/, fn -> Tune.limit(study, concurrency: 0) end
    assert_raise ArgumentError, ~r/cases/, fn -> Tune.limit(study, cases: "1") end

    assert_raise ArgumentError, ~r/high greater than low/, fn ->
      Tune.score(study, :value, & &1, range: {2, 1})
    end

    assert_raise ArgumentError, ~r/keyword list/, fn -> Tune.new(1, [:invalid]) end

    assert {:error, %Error.Invalid.Option{option: :request_options}} =
             ModelConfig.new(
               model: Transport.model(),
               adapter: Tune.Adapter.Chat,
               request_options: [:invalid]
             )

    assert {:error, %Error.Invalid.Option{option: :tools}} =
             ModelConfig.new(
               model: Transport.model(),
               adapter: Tune.Adapter.Chat,
               request_options: [tools: []]
             )
  end

  test "rejects invalid genetic search settings before opening a data factory" do
    assert {:error, %Error.Invalid.Option{option: :genetic, message: message}} =
             Tune.new(%{value: 0}, run: fn target, input -> target.value + input end)
             |> Tune.data(validation: fn -> flunk("the search must validate settings first") end)
             |> Tune.vary(value: 0..1)
             |> Tune.score(:value, & &1)
             |> Tune.search(:genetic, population_size: 0)
             |> Tune.tune()

    assert message =~ "population_size"
  end
end
