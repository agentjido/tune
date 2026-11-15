defmodule Tune do
  @moduledoc """
  Lazy evaluation and search pipelines for Elixir values and LLM programs.

  Start with `new/2`, add declarations, and end with `preview/2`, `evaluate/2`,
  or `tune/1`. Builder calls only return a new `%Tune{}` value.
  """

  alias Tune.Artifact
  alias Tune.Pipeline.Compiler
  alias Tune.Program
  alias Tune.Result
  alias Tune.Score

  @enforce_keys [:target]
  defstruct target: nil,
            runner: nil,
            data: %{},
            variations: %{},
            scores: [],
            selector: nil,
            strategy: nil,
            limits: %{},
            models: %{},
            metadata: %{}

  @type t :: %__MODULE__{
          target: term(),
          runner: function() | nil,
          data: map(),
          variations: map(),
          scores: [map()],
          selector: term(),
          strategy: term(),
          limits: map(),
          models: map(),
          metadata: map()
        }

  @new_options [:run, :model, :teacher, :proposal, :metadata]
  @data_roles [:train, :validation, :test]
  @limit_options [
    :model_calls,
    :evaluations,
    :cases,
    :concurrency,
    :row_timeout,
    :row_calls,
    :deadline,
    :steps,
    :seed
  ]

  @doc "Creates a lazy Tune pipeline."
  @spec new(term(), keyword()) :: t()
  def new(target, opts \\ []) when is_list(opts) do
    ensure_keys!(opts, @new_options, "new")
    runner = Keyword.get(opts, :run)

    if runner != nil and not is_function(runner) do
      raise ArgumentError, "the :run option must be a function"
    end

    metadata = Keyword.get(opts, :metadata, %{})

    if not is_map(metadata) do
      raise ArgumentError, "the :metadata option must be a map"
    end

    %__MODULE__{
      target: target,
      runner: runner,
      models:
        opts
        |> Keyword.take([:model, :teacher, :proposal])
        |> Map.new(),
      metadata: metadata
    }
  end

  @doc "Adds named train, validation, or test data without consuming it."
  @spec data(t(), keyword() | map()) :: t()
  def data(%__MODULE__{} = tune, data) when is_list(data) or is_map(data) do
    data = Map.new(data)
    ensure_map_keys!(data, @data_roles, "data")
    Enum.each(data, fn {role, source} -> validate_source!(role, source) end)
    %{tune | data: Map.merge(tune.data, data)}
  end

  @doc "Declares named values that a search strategy can change."
  @spec vary(t(), keyword() | map()) :: t()
  def vary(%__MODULE__{} = tune, variations) when is_list(variations) or is_map(variations) do
    variations = Map.new(variations)

    if Enum.any?(variations, fn {name, _value} -> not is_atom(name) end) do
      raise ArgumentError, "variation names must be atoms"
    end

    %{tune | variations: Map.merge(tune.variations, variations)}
  end

  @doc "Adds one uniquely named score."
  @spec score(t(), atom(), function() | module(), keyword()) :: t()
  def score(%__MODULE__{} = tune, name, metric, opts \\ [])
      when is_atom(name) and is_list(opts) do
    if Enum.any?(tune.scores, &(&1.name == name)) do
      raise ArgumentError, "duplicate score name #{inspect(name)}"
    end

    %{tune | scores: tune.scores ++ [Score.new!(name, metric, opts)]}
  end

  @doc "Selects the score policy used to compare candidates."
  @spec select(t(), atom() | keyword()) :: t()
  def select(%__MODULE__{} = tune, name) when is_atom(name),
    do: %{tune | selector: {:score, name}}

  def select(%__MODULE__{} = tune, weighted: weights) when is_list(weights) do
    if weights == [] or
         Enum.any?(weights, fn {name, weight} ->
           not is_atom(name) or not is_number(weight) or weight <= 0
         end) do
      raise ArgumentError, "weighted selection requires score names and positive weights"
    end

    %{tune | selector: {:weighted, Map.new(weights)}}
  end

  @doc "Selects a search strategy without starting it."
  @spec search(t(), atom() | module(), keyword()) :: t()
  def search(%__MODULE__{} = tune, strategy, opts \\ [])
      when is_atom(strategy) and is_list(opts) do
    %{tune | strategy: {strategy, opts}}
  end

  @doc "Adds explicit work limits."
  @spec limit(t(), keyword() | map()) :: t()
  def limit(%__MODULE__{} = tune, limits) when is_list(limits) or is_map(limits) do
    limits = Map.new(limits)
    ensure_map_keys!(limits, @limit_options, "limit")
    Enum.each(limits, &validate_limit!/1)
    %{tune | limits: Map.merge(tune.limits, limits)}
  end

  @doc "Prepares one inspectable prompt without making a model call."
  @spec preview(t(), map() | {String.t(), map()}) ::
          {:ok, Tune.Prepared.t()} | {:error, Exception.t()}
  def preview(%__MODULE__{} = tune, input) do
    Compiler.preview(tune, input)
  end

  @doc "Evaluates the pipeline target on test data, or on an explicit data role."
  @spec evaluate(t(), atom()) :: {:ok, Tune.Evaluation.t()} | {:error, Exception.t()}
  def evaluate(%__MODULE__{} = tune, role \\ :test) when role in @data_roles do
    Compiler.evaluate(tune, role)
  end

  @doc "Runs the selected search and returns one immutable result."
  @spec tune(t()) :: {:ok, Result.t()} | {:error, Exception.t()}
  def tune(%__MODULE__{} = tune), do: Compiler.tune(tune)

  @doc "Builds a versioned artifact from a completed tuning result."
  @spec dump(Result.t()) :: {:ok, Artifact.t()} | {:error, Exception.t()}
  def dump(%Result{} = result), do: Artifact.from_result(result)

  @doc "Validates an artifact and applies it to fresh application code."
  @spec load(Artifact.t(), Program.t()) :: {:ok, Program.t()} | {:error, Exception.t()}
  def load(%Artifact{} = artifact, fresh_target), do: Artifact.apply(artifact, fresh_target)

  defp validate_source!(_role, source) when is_function(source, 0), do: :ok

  defp validate_source!(role, source) do
    if is_nil(Enumerable.impl_for(source)) do
      raise ArgumentError, "#{role} data must implement Enumerable or be a zero-arity function"
    end
  end

  defp validate_limit!({key, value}) when key in [:model_calls, :evaluations, :cases, :steps] do
    if not (is_integer(value) and value >= 0) do
      raise ArgumentError, "#{key} must be a nonnegative integer"
    end
  end

  defp validate_limit!({key, value}) when key in [:concurrency, :row_timeout, :row_calls] do
    if not (is_integer(value) and value > 0) do
      raise ArgumentError, "#{key} must be a positive integer"
    end
  end

  defp validate_limit!({:deadline, :infinity}), do: :ok

  defp validate_limit!({:deadline, value}) when is_integer(value) and value >= 0, do: :ok
  defp validate_limit!({:seed, value}) when is_integer(value), do: :ok
  defp validate_limit!({key, _value}), do: raise(ArgumentError, "invalid #{key} limit")

  defp ensure_keys!(opts, allowed, name), do: ensure_map_keys!(Map.new(opts), allowed, name)

  defp ensure_map_keys!(map, allowed, name) do
    case Map.keys(map) -- allowed do
      [] -> :ok
      [key | _] -> raise ArgumentError, "unknown #{name} option #{inspect(key)}"
    end
  end
end
