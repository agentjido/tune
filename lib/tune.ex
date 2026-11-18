defmodule Tune do
  @moduledoc """
  Lazy evaluation and search pipelines for Elixir values and LLM programs.

  Start with `new/2`, add declarations, and end with `preview/2`, `evaluate/2`,
  `tune/1`, or `compare/3`. Builder calls only return a new `%Tune{}` value.
  """

  alias Tune.Artifact
  alias Tune.Comparison
  alias Tune.Input
  alias Tune.Limits
  alias Tune.Pipeline.Compiler
  alias Tune.Result
  alias Tune.Score

  @enforce_keys [:target]
  defstruct target: nil,
            runner: nil,
            on_progress: nil,
            cancel: nil,
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
          runner: function() | :replay | nil,
          on_progress: (map() -> term()) | nil,
          cancel: (-> boolean()) | nil,
          data: map(),
          variations: map(),
          scores: [map()],
          selector: term(),
          strategy: term(),
          limits: map(),
          models: map(),
          metadata: map()
        }

  @options Zoi.keyword(
             [
               run: Zoi.function() |> Zoi.nullable(),
               on_progress: Zoi.function(arity: 1) |> Zoi.nullable(),
               cancel: Zoi.function(arity: 0) |> Zoi.nullable(),
               metadata: Zoi.map() |> Zoi.default(%{}),
               model: Zoi.any(),
               teacher: Zoi.any(),
               proposal: Zoi.any()
             ],
             unrecognized_keys: :error
           )
  @data_roles [:train, :validation, :test]

  @doc "Creates a lazy Tune pipeline."
  @spec new(term(), keyword()) :: t()
  def new(target, opts \\ []) when is_list(opts) do
    parsed =
      case Input.options(@options, opts, :new, :first) do
        {:ok, values} -> values
        {:error, error} -> raise ArgumentError, Exception.message(error)
      end

    %__MODULE__{
      target: target,
      runner: parsed[:run],
      on_progress: parsed[:on_progress],
      cancel: parsed[:cancel],
      models:
        opts
        |> Keyword.take([:model, :teacher, :proposal])
        |> Map.new(),
      metadata: parsed[:metadata]
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

  @doc """
  Builds an evaluation study from saved rows with `input` and `output` fields.

  Rows may also provide `id` and `expected`. Pass an Enumerable or a zero-arity
  factory. Score saved output with a function that takes `(case, output)`.
  """
  @spec replay(Enumerable.t() | (-> Enumerable.t()), keyword()) :: t()
  def replay(rows, opts \\ []), do: Tune.Replay.study(rows, opts)

  @doc "Declares named values that a search strategy can change."
  @spec vary(t(), keyword() | map()) :: t()
  def vary(%__MODULE__{} = tune, variations) when is_list(variations) or is_map(variations) do
    variations = Map.new(variations)

    if Enum.any?(variations, fn {name, _value} -> not is_atom(name) end) do
      raise ArgumentError, "variation names must be atoms"
    end

    %{tune | variations: Map.merge(tune.variations, variations)}
  end

  @doc """
  Adds one uniquely named score.

  Use `argument: :output` with a two-argument scorer for `(case, output)`.
  Use `argument: :prediction` for `(case, prediction)` on program runs.
  The default preserves the existing behavior: a two-argument function or
  module receives the prediction when available and the output otherwise.
  """
  @spec score(t(), atom(), function() | module() | struct(), keyword()) :: t()
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
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "search options must be a keyword list")

    %{tune | strategy: {strategy, opts}}
  end

  @doc "Adds explicit work limits."
  @spec limit(t(), keyword() | map()) :: t()
  def limit(%__MODULE__{} = tune, limits) when is_list(limits) or is_map(limits) do
    case Limits.cast(Map.new(limits)) do
      {:ok, limits} -> %{tune | limits: Map.merge(tune.limits, limits)}
      {:error, errors} -> raise ArgumentError, Input.format(errors)
    end
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

  @doc "Compares the original target and the search winner on an explicit split."
  @spec compare(t(), Result.t(), keyword()) :: {:ok, Comparison.t()} | {:error, Exception.t()}
  def compare(%__MODULE__{} = tune, %Result{} = winner, opts) do
    case opts do
      [split: split] when split in @data_roles ->
        Compiler.compare(tune, winner.value, split)

      _ ->
        {:error, Tune.Error.Invalid.Option.exception(option: :split, message: "choose a split")}
    end
  end

  @doc "Builds a versioned artifact from a completed tuning result."
  @spec dump(Result.t()) :: {:ok, Artifact.t()} | {:error, Exception.t()}
  def dump(%Result{} = result), do: Artifact.from_result(result)

  @doc "Validates an artifact and applies it to fresh application code."
  @spec load(Artifact.t(), term()) :: {:ok, term()} | {:error, Exception.t()}
  def load(%Artifact{} = artifact, fresh_target), do: Artifact.apply(artifact, fresh_target)

  defp validate_source!(_role, source) when is_function(source, 0), do: :ok

  defp validate_source!(role, source) do
    if is_nil(Enumerable.impl_for(source)) do
      raise ArgumentError, "#{role} data must implement Enumerable or be a zero-arity function"
    end
  end

  defp ensure_map_keys!(map, allowed, name) do
    case Map.keys(map) -- allowed do
      [] -> :ok
      [key | _] -> raise ArgumentError, "unknown #{name} option #{inspect(key)}"
    end
  end
end
