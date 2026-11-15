defmodule Tune.UI do
  @moduledoc """
  Starts the optional local Tune workbench.

  The workbench requires `phoenix_playground` in the host application's
  dependencies. It binds only to the loopback interface and keeps state in
  memory for the life of the VM.
  """

  @doc "Starts the local multi-route workbench."
  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts \\ []) do
    playground = Module.concat([PhoenixPlayground])
    router = Module.concat([Tune, UI, Router])
    port = Keyword.get(opts, :port, 4000)

    with :ok <- require_module(playground, "phoenix_playground is not installed"),
         :ok <- require_module(router, "Tune UI was compiled without Phoenix Playground") do
      configure_recipes(Keyword.get(opts, :recipes, []))

      playground.start(
        plug: router,
        child_specs: [
          Tune.UI.Store,
          {Task.Supervisor, name: Tune.UI.TaskSupervisor}
        ],
        ip: {127, 0, 0, 1},
        host: "localhost",
        port: port,
        endpoint_options: [
          check_origin: ["//localhost:#{port}", "//127.0.0.1:#{port}"]
        ],
        open_browser: Keyword.get(opts, :open_browser, true),
        debug_errors: Keyword.get(opts, :debug_errors, true),
        live_reload: false
      )
    end
  end

  defp configure_recipes([]), do: :ok

  defp configure_recipes(recipes) when is_list(recipes) do
    current = Application.get_env(:tune, __MODULE__, [])
    Application.put_env(:tune, __MODULE__, Keyword.put(current, :recipes, recipes))
  end

  defp require_module(module, message) do
    if Code.ensure_loaded?(module),
      do: :ok,
      else: {:error, Tune.Error.Invalid.Option.exception(option: :ui, message: message)}
  end
end
