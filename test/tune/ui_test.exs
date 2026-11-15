defmodule Tune.UITest do
  use ExUnit.Case, async: false

  alias Tune.UI.Registry
  alias Tune.UI.Store

  setup do
    start_supervised!(Store)
    :ok
  end

  test "the optional router exposes the workbench routes" do
    routes =
      Tune.UI.Router.__routes__()
      |> Enum.map(&{&1.verb, &1.path})
      |> MapSet.new()

    expected = [
      {:get, "/"},
      {:get, "/studies"},
      {:get, "/studies/new"},
      {:get, "/studies/:id"},
      {:get, "/studies/:id/settings"},
      {:get, "/studies/:id/data"},
      {:get, "/studies/:id/preview"},
      {:get, "/studies/:id/run"},
      {:get, "/runs/:id"},
      {:get, "/artifacts"},
      {:get, "/settings"},
      {:get, "/runs/:id/artifact"}
    ]

    assert MapSet.subset?(MapSet.new(expected), routes)
  end

  test "the store creates and updates studies without persistence" do
    assert {:ok, study} =
             Store.create_study(%{
               name: "Grounded QA",
               recipe: "structured_prompt",
               config: %{"model" => "test:model"},
               data: %{train: []}
             })

    assert Store.get_study(study.id) == study

    assert {:ok, updated} =
             Store.update_study(study.id, %{data: %{train: [%{"inputs" => %{}, "labels" => %{}}]}})

    assert updated.id == study.id
    assert updated.inserted_at == study.inserted_at
    assert length(updated.data.train) == 1
  end

  test "the registry resolves only declared recipe IDs" do
    assert {:ok, Tune.UI.Recipes.StructuredPrompt} = Registry.fetch("structured_prompt")
    assert {:error, %Tune.Error.Invalid.Definition{}} = Registry.fetch("Elixir.System")
  end

  test "known model suggestions include models used by studies" do
    assert {:ok, _study} =
             Store.create_study(%{
               name: "Local model",
               recipe: "structured_prompt",
               config: %{"model" => "lmstudio:local-model"},
               data: %{}
             })

    assert "lmstudio:local-model" in Tune.UI.Components.known_models()
  end

  test "the grounded QA example is complete and previewable offline" do
    attrs = Tune.UI.Examples.grounded_qa()

    assert length(attrs.data.train) == 2
    assert length(attrs.data.validation) == 1
    assert length(attrs.data.test) == 1
    assert {:ok, study} = Store.create_study(attrs)
    assert {:ok, pipeline} = Tune.UI.Recipes.StructuredPrompt.build(study)
    assert {:ok, input} = Tune.UI.Recipes.StructuredPrompt.preview_input(study)
    assert {:ok, prepared} = Tune.preview(pipeline, input)
    assert prepared.inputs == input
  end

  test "the built-in recipe builds a lazy pipeline and previews offline" do
    config = Tune.UI.Recipes.StructuredPrompt.default_config()

    assert {:ok, study} =
             Store.create_study(%{
               name: "Classifier",
               recipe: "structured_prompt",
               config: config,
               data: %{
                 train: [
                   %{
                     "inputs" => %{"input" => "hello"},
                     "labels" => %{"output" => "greeting"}
                   }
                 ]
               }
             })

    recipe = Tune.UI.Recipes.StructuredPrompt

    assert {:ok, %Tune{} = pipeline} = recipe.build(study)
    assert pipeline.strategy == {:labeled_few_shot, [k: 4, sample: false]}
    assert {:ok, %{"input" => "hello"} = input} = recipe.preview_input(study)
    assert {:ok, prepared} = Tune.preview(pipeline, input)
    assert prepared.inputs == %{"input" => "hello"}
  end
end
