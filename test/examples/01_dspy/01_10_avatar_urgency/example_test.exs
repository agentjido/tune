defmodule Tune.Examples.AvatarUrgencyTest do
  use ExUnit.Case, async: true

  @moduletag :example

  alias Tune.Examples.Support.SupportGuide
  alias Tune.Examples.Support.Transport

  test "good and bad traces change only the named predictor" do
    assert %{result: {:ok, report}, requests: [contrast, rewrite]} = SupportGuide.avatar()
    assert report.value.classify == SupportGuide.new().classify
    assert report.value.urgency.signature.instructions == "Urgent when a payment is blocked."
    assert Transport.prompt_text(contrast) =~ "Routine invoice request"
    assert Transport.prompt_text(contrast) =~ "Payment blocked before closing"
    assert Transport.prompt_text(rewrite) =~ "Blocked payments were classified as routine."
  end

  test "missing negative evidence stops without asking for a rewrite" do
    assert %{requests: [], result: {:ok, report}} =
             SupportGuide.avatar(train: [SupportGuide.row("Routine invoice request", "routine")])

    assert report.metadata.notes.stop == :no_contrast
    assert report.value == SupportGuide.new()
  end
end
