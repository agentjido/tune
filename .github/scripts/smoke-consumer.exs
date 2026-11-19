study =
  Tune.new(%{weight: 1}, run: fn config, value -> config.weight * value end)
  |> Tune.data(validation: [2], test: [3])
  |> Tune.score(:value, & &1)
  |> Tune.vary(weight: 1..3)
  |> Tune.search(:grid)

{:ok, %Tune.Evaluation{selected_score: 3.0}} = Tune.evaluate(study)
{:ok, winner} = Tune.tune(study)

{:ok, %Tune.Comparison{challenger: %Tune.Evaluation{selected_score: 9.0}}} =
  Tune.compare(study, winner, split: :test)

case System.fetch_env!("TUNE_SMOKE_MODE") do
  "core" ->
    false = Code.ensure_loaded?(PhoenixPlayground)
    false = Code.ensure_loaded?(Tune.UI.Router)

  "workbench" ->
    true = Code.ensure_loaded?(Mix.Tasks.Tune.Ui)

    try do
      {:ok, _pid} = Tune.UI.start(port: 0, open_browser: false)
      {:ok, {{127, 0, 0, 1}, port}} = PhoenixPlayground.Endpoint.server_info(:http)
      %{status: 200, body: body} = Req.get!("http://127.0.0.1:#{port}/")
      true = String.contains?(body, "Tune dashboard")
    after
      System.no_halt(false)
      Supervisor.terminate_child(PhoenixPlayground.Application, PhoenixPlayground)
    end
end

IO.puts("Tune consumer smoke check passed.")
