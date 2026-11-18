defmodule Tune.Examples.StreamedCSV do
  @moduledoc "Parse a small CSV stream in application code and score it."

  @csv_path Path.join(__DIR__, "fixtures/support.csv")

  def csv do
    fn -> File.stream!(@csv_path) |> Stream.drop(1) |> Stream.map(&parse_csv/1) end
    |> Tune.replay()
    |> Tune.score(:exact_match, &exact/2, failure_score: 0)
    |> Tune.score(:abstention, &abstention/2)
    |> Tune.score(:cost, fn _row, output -> output.cost end, direction: :minimize)
    |> Tune.select(:exact_match)
    |> Tune.evaluate()
  end

  defp parse_csv(line) do
    [id | columns] = line |> String.trim_trailing() |> String.split(",")

    with [expected, answer, cost] <- columns,
         {cost, ""} <- Float.parse(cost) do
      %{id: id, input: id, expected: expected, output: %{answer: answer, cost: cost}}
    else
      _ -> %{id: id, input: %{parse_error: "expected answer, prediction and numeric cost"}}
    end
  end

  defp exact(row, output), do: if(row.expected == output.answer, do: 1, else: 0)

  defp abstention(row, output),
    do: if(row.expected == "abstain" == (output.answer == "abstain"), do: 1, else: 0)
end
