if Code.ensure_loaded?(PhoenixPlayground) do
  defmodule Tune.UI.Web do
    @moduledoc false

    defmacro __using__(:live_view) do
      quote do
        use Phoenix.LiveView
        import Tune.UI.Components
      end
    end
  end
end
