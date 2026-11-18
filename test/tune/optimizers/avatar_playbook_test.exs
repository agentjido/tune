defmodule Tune.Optimizers.AvatarPlaybookTest do
  use ExUnit.Case, async: true

  alias Tune
  alias Tune.Adapter
  alias Tune.Artifact
  alias Tune.Examples.Support.GroundedQA
  alias Tune.Examples.Support.QAWorld
  alias Tune.Examples.Support.Transport
  alias Tune.Optimizers.Avatar
  alias Tune.Optimizers.Playbook

  defp config(stub),
    do: [
      model: Transport.model(),
      adapter: Adapter.Chat,
      request_options: Transport.request_options(stub)
    ]

  defp train,
    do:
      QAWorld.rows([
        {"What is Alpha?", "alpha", "first"},
        {"What is Beta?", "beta", "second"},
        {"What is Kappa?", "kappa", "tenth"}
      ])

  defp val,
    do:
      QAWorld.rows([
        {"What is Gamma?", "gamma", "third"},
        {"What is Delta?", "delta", "HIDDEN-ANSWER"}
      ])

  defp optimize(optimizer, target, proposal, extra \\ []) do
    Tune.TestSupport.Search.run(GroundedQA.new(),
      search: optimizer,
      train: Keyword.get(extra, :train, train()),
      validation: val(),
      metric: &QAWorld.metric/2,
      model: config(target),
      proposal: config(proposal),
      model_calls: 200
    )
  end

  describe "Avatar" do
    defp avatar_target(overrides \\ %{}) do
      QAWorld.stub(
        overrides: overrides,
        quality: fn prompt, answer ->
          if prompt =~ "Say the fact" or answer == "first", do: answer, else: "unsure"
        end
      )
    end

    defp avatar_proposal do
      Transport.respond_with(fn body ->
        prompt = Transport.prompt_text(body)

        if prompt =~ "[[ ## successful_examples ## ]]",
          do: Transport.chat(feedback: "Unsuccessful answers ignore the fact text."),
          else: Transport.chat(new_instruction: "Say the fact from the passage and cite it.")
      end)
    end

    test "contrasting good and bad trajectories rewrites only the named predictor" do
      proposal = avatar_proposal()

      assert {:ok, best, report} =
               optimize(
                 {Avatar, predictor: "answer", upper_bound: 1.0, lower_bound: 0.0, max_iters: 1},
                 avatar_target(),
                 proposal
               )

      assert best.answer.signature.instructions == "Say the fact from the passage and cite it."
      assert best.extract == GroundedQA.new().extract
      assert report.best.metadata.label == "avatar_1"

      [contrast, rewrite] = Transport.requests(proposal)
      contrast_text = Transport.last_user_text(contrast)

      [positive_part, negative_part] =
        String.split(contrast_text, "[[ ## unsuccessful_examples ## ]]", parts: 2)

      assert positive_part =~ "Alpha"
      assert negative_part =~ "Beta"
      assert Transport.prompt_text(rewrite) =~ "Unsuccessful answers ignore the fact text."
      assert report.calls.proposal == 2
    end

    test "failures are negative, never positive" do
      assert {:ok, _best, report} =
               optimize(
                 {Avatar, predictor: "answer", upper_bound: 1.0, lower_bound: 0.0, max_iters: 1},
                 avatar_target(%{
                   "What is Alpha?" => :fail_answer,
                   "What is Beta?" => {:answer, "second"}
                 }),
                 avatar_proposal()
               )

      [record] = report.metadata.notes.iterations
      assert "0" in record.negative
      refute "0" in record.positive
      assert record.positive == ["1"]
    end

    test "absent positive or negative groups stop cleanly with the best validated program" do
      all_good = QAWorld.stub()

      assert {:ok, best, report} =
               optimize(
                 {Avatar, predictor: "answer", upper_bound: 1.0, lower_bound: 0.0},
                 all_good,
                 avatar_proposal(),
                 train: QAWorld.rows([{"What is Alpha?", "alpha", "first"}])
               )

      assert best == GroundedQA.new()
      assert report.metadata.notes.stop == :no_contrast
      assert report.calls[:proposal] == nil
    end

    test "configuration is explicit" do
      assert {:error, %Tune.Error.Invalid.Option{option: :upper_bound}} =
               optimize({Avatar, predictor: "answer"}, :unused, :unused)

      assert {:error, %Tune.Error.Optimization.Failed{}} =
               optimize(
                 {Avatar, predictor: "missing", upper_bound: 1, lower_bound: 0},
                 QAWorld.stub(),
                 :unused
               )
    end
  end

  describe "Playbook" do
    defp lesson_target,
      do:
        QAWorld.stub(
          quality: fn prompt, answer ->
            if prompt =~ "- Quote the source.", do: answer, else: "unsure"
          end
        )

    defp lessons(list), do: Transport.respond_with(fn _ -> Transport.chat(lessons: list) end)

    test "a useful lesson improves the score and is used by application code" do
      proposal = lessons(["Quote the source."])

      assert {:ok, best, report} =
               optimize({Playbook, parameter: "lessons", rounds: 1}, lesson_target(), proposal)

      assert best.lessons.value == ["Quote the source."]
      assert report.best.metadata.label == "round_1"
      assert hd(report.history).metadata.label == "baseline"

      for body <- Transport.requests(proposal) do
        text = Transport.prompt_text(body)
        assert text =~ "Alpha"
        refute text =~ "Gamma"
        refute text =~ "HIDDEN-ANSWER"
      end

      {:ok, artifact} = Tune.dump(report)
      assert artifact.parameters["lessons"]["value"] == ["Quote the source."]
      {:ok, json} = Artifact.encode(artifact)
      refute json =~ "fn"
    end

    test "a lesson that does not help keeps the baseline" do
      assert {:ok, best, _report} =
               optimize(
                 {Playbook, parameter: "lessons", rounds: 1},
                 lesson_target(),
                 lessons(["Be quick."])
               )

      assert best.lessons.value == []
    end

    test "oversize, too many, and invalid proposals are rejected" do
      cases = [
        {lessons(Enum.map(1..9, &"Lesson #{&1}.")), "more than"},
        {lessons([String.duplicate("x", 500)]), "exceeds"},
        {Transport.respond_with(fn _ -> Transport.chat(lessons: [1, 2]) end), "no valid proposal"}
      ]

      for {proposal, reason} <- cases do
        assert {:ok, best, report} =
                 optimize({Playbook, parameter: "lessons", rounds: 1}, lesson_target(), proposal)

        assert best.lessons.value == []
        assert [%{accepted?: false, reason: message}] = report.metadata.notes.rounds
        assert message =~ reason
      end
    end

    test "growth is bounded per round" do
      config = %{max_lessons: 8, max_new: 1, max_lesson_bytes: 400, max_total_bytes: 4000}
      assert :ok = Playbook.check_growth(config, ["a"], ["a", "b"])
      assert {:error, _} = Playbook.check_growth(config, ["a"], ["a", "b", "c"])
    end

    test "the parameter must hold a list of strings" do
      assert {:error, %Tune.Error.Optimization.Failed{}} =
               optimize({Playbook, parameter: "answer"}, QAWorld.stub(), lessons([]))
    end
  end
end
