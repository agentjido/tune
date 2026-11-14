defmodule Tune.TestSupport.Search do
  @moduledoc false

  def run(program, opts) do
    case Tune.Search.Program.run(program, opts) do
      {:ok, result} -> {:ok, result.value, result}
      error -> error
    end
  end
end
