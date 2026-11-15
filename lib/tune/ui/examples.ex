defmodule Tune.UI.Examples do
  @moduledoc false

  @spec grounded_qa() :: map()
  def grounded_qa do
    %{
      name: "Grounded QA example",
      recipe: "structured_prompt",
      config: %{
        "instructions" =>
          "Answer the question using only the supplied context. Return unknown when the context does not contain the answer.",
        "input_name" => "input",
        "output_name" => "output",
        "output_type" => "string",
        "model" => "openai:gpt-4o-mini",
        "teacher_model" => "",
        "proposal_model" => "",
        "adapter" => "chat",
        "strategy" => "labeled_few_shot",
        "strategy_options" => %{"k" => 2, "sample" => false},
        "limits" => %{"model_calls" => 24, "seed" => 0}
      },
      data: %{
        train: [
          row("The Eiffel Tower is in Paris.", "Where is the Eiffel Tower?", "Paris"),
          row(
            "Jane Austen wrote Pride and Prejudice.",
            "Who wrote Pride and Prejudice?",
            "Jane Austen"
          )
        ],
        validation: [
          row(
            "Plants absorb carbon dioxide during photosynthesis.",
            "Which gas do plants absorb?",
            "carbon dioxide"
          )
        ],
        test: [
          row(
            "Jupiter is the largest planet in the solar system.",
            "What is the largest planet?",
            "Jupiter"
          )
        ]
      }
    }
  end

  defp row(context, question, answer) do
    %{
      "inputs" => %{"input" => "Context: #{context}\nQuestion: #{question}"},
      "labels" => %{"output" => answer}
    }
  end
end
