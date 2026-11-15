defmodule Mix.Tasks.Tune.Ui do
  @shortdoc "Starts the local Tune workbench"
  @moduledoc """
  Starts the optional local Tune workbench.

      mix tune.ui
      mix tune.ui --port 4100 --no-open

  The host project must declare `phoenix_playground` as a dependency.
  """

  use Mix.Task

  @switches [port: :integer, open: :boolean]
  @aliases [p: :port]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    if rest != [] or invalid != [] do
      Mix.raise("usage: mix tune.ui [--port PORT] [--no-open]")
    end

    Mix.Task.run("app.start")

    start_opts = [
      port: Keyword.get(opts, :port, 4000),
      open_browser: Keyword.get(opts, :open, true)
    ]

    case Tune.UI.start(start_opts) do
      {:ok, _pid} ->
        Mix.shell().info("Tune workbench is available at http://localhost:#{start_opts[:port]}")
        Process.sleep(:infinity)

      {:error, error} ->
        Mix.raise(Exception.message(error))
    end
  end
end
