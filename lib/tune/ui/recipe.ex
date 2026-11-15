defmodule Tune.UI.Recipe do
  @moduledoc "The application-code boundary used by the optional Tune UI."

  @callback id() :: String.t()
  @callback label() :: String.t()
  @callback description() :: String.t()
  @callback default_config() :: map()
  @callback build(Tune.UI.Study.t()) :: {:ok, Tune.t()} | {:error, term()}
  @callback preview_input(Tune.UI.Study.t()) :: {:ok, term()} | {:error, term()}
end
