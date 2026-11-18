defmodule Tune.Examples.SearchDemosTest do
  use ExUnit.Case, async: true

  @moduletag :example

  alias Tune.Examples.SearchDemos

  test "both search methods find the best demo on the same fixture" do
    assert {:ok, random} = SearchDemos.search(:random)
    assert {:ok, tpe} = SearchDemos.search(:tpe)

    for report <- [random, tpe] do
      assert report.best.evaluation.selected_score == 1.0
      assert [%{inputs: %{"ticket" => "invoice 5"}}] = report.value.demos
    end

    trials = tpe.metadata.notes.trials
    assert length(trials) == 12
    assert Enum.count(Enum.drop(trials, 3), fn {_choice, score} -> score == 1.0 end) > 4
    assert length(tpe.history) < length(trials)
  end

  test "budget stop keeps the fully validated winner and charges the interrupted evaluation" do
    assert {:ok, report} = SearchDemos.search(:tpe, model_calls: 15)
    refute report.complete?
    assert report.best.evaluation.complete?
    assert report.best.evaluation.selected_score == 1.0
    assert Enum.sum(Map.values(report.calls)) <= 15
  end
end
