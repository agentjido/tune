defmodule Tune.Optimizers.Anything do
  @moduledoc """
  The Optimize.Anything target: GEPA-style search over one declared value.

  The named `Tune.Parameter` is the only component of the
  reflective search in `Tune.Optimizers.Reflective`. The proposal
  role sees the parameter's description, JSON Schema, current value, and
  training trajectories with scores and feedback, and returns a new value as
  text: raw text for a string schema, JSON otherwise. Every proposal is
  validated against the parameter schema before use; invalid proposals are
  discarded. Application code decides how the value is used in its named
  calls, through `Tune.Execution.value/2`. No other parameter changes.

  Options: `:parameter` (required name), `:objective` (text describing what
  the value is for; defaults to the parameter description), and the
  reflective options `:max_iterations` and `:minibatch_size`. This strategy
  searches a single component, so merging is disabled.

  Differences from `gepa.optimize_anything`: the value is evaluated through
  a normal parameterized program and metric rather than a separate
  evaluator/adapter interface.
  """

  @behaviour Tune.Search.ProgramStrategy

  alias Tune.Field
  alias Tune.Optimizers.Proposals
  alias Tune.Optimizers.Reflective
  alias Tune.Optimizers.Shared
  alias Tune.Parameter
  alias Tune.Search.Program.Context

  @fields [
    parameter: Zoi.string() |> Zoi.required(),
    objective: Zoi.string() |> Zoi.nullable() |> Zoi.default(nil)
  ]

  @impl true
  def init(opts) do
    with {:ok, config} <- Shared.options(Reflective.options(@fields), opts) do
      {:ok, %{config | use_merge: false}}
    end
  end

  @impl true
  def requirements(_config),
    do: %{datasets: [:train, :validation], roles: [:proposal], model_calls?: true}

  @impl true
  def compile(config, program, %Context{} = ctx) do
    case Map.new(Shared.values(program)) |> Map.fetch(config.parameter) do
      {:ok, %Parameter{} = parameter} ->
        Reflective.run(config, program, [component(config, parameter)], ctx)

      :error ->
        {:error,
         elem(
           Shared.option_error(
             :parameter,
             "#{inspect(config.parameter)} is not a declared value parameter"
           ),
           1
         ), ctx}
    end
  end

  @doc "Renders a parameter value as proposal text."
  @spec to_text(Parameter.t() | Zoi.schema(), term()) :: String.t()
  def to_text(%Parameter{schema: schema}, value), do: to_text(schema, value)
  def to_text(%Zoi.Types.String{}, value) when is_binary(value), do: value
  def to_text(_schema, value), do: JSON.encode!(value)

  @doc "Parses proposal text into a value for a schema, without validation."
  @spec from_text(Zoi.schema(), String.t()) :: {:ok, term()} | :error
  def from_text(%Zoi.Types.String{}, text), do: {:ok, text}

  def from_text(_schema, text) do
    case JSON.decode(text) do
      {:ok, value} -> {:ok, value}
      {:error, _} -> :error
    end
  end

  defp component(config, %Parameter{schema: schema} = parameter) do
    name = config.parameter
    objective = config.objective || parameter.description || "Improve the value of #{name}."
    schema_text = JSON.encode!(Field.json_schema(schema))

    %{
      name: name,
      get: fn program ->
        program
        |> Shared.values()
        |> Map.new()
        |> Map.fetch!(name)
        |> then(&to_text(&1, &1.value))
      end,
      put: fn program, text ->
        with {:ok, value} <- from_text(schema, text) do
          Shared.put_value(program, name, value)
        end
      end,
      propose: fn ctx, current, feedback ->
        {text, ctx} = Proposals.value(ctx, objective, schema_text, current, feedback)
        {text && String.trim(text), ctx}
      end
    }
  end
end
