if Code.ensure_loaded?(PhoenixPlayground) do
  defmodule Tune.UI.ArtifactController do
    @moduledoc false
    use Phoenix.Controller, formats: [:html]

    def show(conn, %{"id" => id}) do
      case Tune.UI.Store.get_run(id) do
        %{artifact: %Tune.Artifact{} = artifact} ->
          {:ok, json} = Tune.Artifact.encode(artifact)

          conn
          |> put_resp_content_type("application/json")
          |> put_resp_header("content-disposition", ~s(attachment; filename="#{id}.json"))
          |> send_resp(200, json)

        _other ->
          send_resp(conn, 404, "artifact not found")
      end
    end
  end
end
