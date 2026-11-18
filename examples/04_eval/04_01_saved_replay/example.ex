defmodule Tune.Examples.SavedReplay do
  @moduledoc "Replay stored answers from a lazy JSONL stream."

  @data_path Path.join(__DIR__, "fixtures/saved.jsonl")

  def run(factory \\ &rows/0, opts \\ []) do
    factory
    |> Tune.replay()
    |> Tune.score(:answer_length, fn _row, output -> String.length(output) end)
    |> Tune.limit(Keyword.take(opts, [:cases]))
    |> Tune.evaluate()
  end

  def rows, do: File.stream!(@data_path) |> Stream.map(&JSON.decode!/1)
end
