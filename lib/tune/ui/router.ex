if Code.ensure_loaded?(PhoenixPlayground) do
  defmodule Tune.UI.Router do
    @moduledoc "The optional local workbench router."
    use Phoenix.Router
    import Phoenix.LiveView.Router

    pipeline :browser do
      plug(:accepts, ["html"])
      plug(:fetch_session)
      plug(:protect_from_forgery)
      plug(:put_root_layout, html: {PhoenixPlayground.Layout, :root})
      plug(:put_secure_browser_headers)
    end

    scope "/" do
      pipe_through(:browser)

      live("/", Tune.UI.DashboardLive)
      live("/studies", Tune.UI.StudyLive.Index)
      live("/studies/new", Tune.UI.StudyLive.New)
      live("/studies/:id", Tune.UI.StudyLive.Show)
      live("/studies/:id/settings", Tune.UI.StudyLive.Settings)
      live("/studies/:id/data", Tune.UI.StudyLive.Data)
      live("/studies/:id/preview", Tune.UI.StudyLive.Preview)
      live("/studies/:id/run", Tune.UI.StudyLive.Run)
      live("/runs/:id", Tune.UI.RunLive.Show)
      live("/artifacts", Tune.UI.ArtifactLive.Index)
      live("/settings", Tune.UI.SettingsLive)
      get("/runs/:id/artifact", Tune.UI.ArtifactController, :show)
    end
  end
end
