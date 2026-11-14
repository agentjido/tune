defmodule Tune.KNN do
  @moduledoc """
  A program that selects nearby training examples for each input.

  For every call it ranks the declared pool by similarity to the input,
  takes the `k` nearest rows (pool order breaks ties), runs the inner program
  on each neighbor under the explicit `:teacher` role to bootstrap
  demonstrations from successful trajectories, adds labeled demonstrations
  when configured, and then runs the inner program with those demonstrations
  under the active role. Every teacher call is a managed call in the same
  execution, so the run needs a teacher configuration and an explicit
  `:max_model_calls`.

  The pool is a declared JSON parameter named `"knn_pool"`, so it is saved in
  artifacts. The vectorizer is application code and is never saved. The
  default vectorizer is a bag of lowercase words over the input values.
  """

  @behaviour Tune.Program

  alias Tune
  alias Tune.Error
  alias Tune.Example
  alias Tune.Execution
  alias Tune.Optimizers.Shared
  alias Tune.Parameter
  alias Tune.Signature

  @pool "knn_pool"
  @scope "knn_bootstrap"

  @enforce_keys [:inner, :pool, :k]
  defstruct [:inner, :pool, :k, max_bootstrapped_demos: 3, max_labeled_demos: 0, vectorizer: nil]

  @type t :: %__MODULE__{}

  @doc """
  Builds a KNN program around an inner program.

  Options: `:pool` (training rows), `:k`, `:max_bootstrapped_demos`,
  `:max_labeled_demos`, and `:vectorizer` (a function of an input map returning
  a list of numbers, or a map of term to weight).
  """
  @spec new(Tune.Program.t(), keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def new(inner, opts) do
    with {:ok, signature} <- Tune.Program.signature(inner),
         {:ok, parameters} <- Tune.Program.parameters(inner),
         :ok <-
           if(Map.has_key?(parameters, @pool),
             do: invalid("the inner program already declares #{@pool}"),
             else: :ok
           ),
         {:ok, rows} <- pool_rows(signature, Keyword.get(opts, :pool, [])),
         {:ok, pool} <- pool_parameter(signature, rows) do
      {:ok,
       %__MODULE__{
         inner: inner,
         pool: pool,
         k: Keyword.get(opts, :k, 3),
         max_bootstrapped_demos: Keyword.get(opts, :max_bootstrapped_demos, 3),
         max_labeled_demos: Keyword.get(opts, :max_labeled_demos, 0),
         vectorizer: Keyword.get(opts, :vectorizer)
       }}
    end
  end

  @doc "Returns the JSON schema used for the pool parameter."
  @spec pool_schema(Signature.t()) :: Zoi.schema()
  def pool_schema(%Signature{} = signature) do
    labels = Zoi.object(Map.new(signature.outputs, &{&1.name, Zoi.optional(&1.schema)}))

    Zoi.array(
      Zoi.object(%{"id" => Zoi.string(), "inputs" => signature.input_schema, "labels" => labels})
    )
  end

  @impl true
  def signature(%__MODULE__{inner: inner}) do
    {:ok, signature} = Tune.Program.signature(inner)
    signature
  end

  @impl true
  def parameters(%__MODULE__{inner: inner, pool: pool}) do
    {:ok, parameters} = Tune.Program.parameters(inner)
    Map.put(parameters, @pool, pool)
  end

  @impl true
  def put_parameters(%__MODULE__{inner: inner} = program, parameters) do
    {pool, inner_parameters} = Map.pop!(parameters, @pool)
    {:ok, inner} = Tune.Program.replace_parameters(inner, inner_parameters)
    %{program | inner: inner, pool: pool}
  end

  @impl true
  def call(%__MODULE__{} = program, inputs, %Execution{} = execution) do
    with :ok <- check_execution(execution),
         {:ok, rows} <- Execution.value(execution, @pool) |> wrap(execution) do
      neighbors = nearest(program, inputs, rows)
      names = Enum.map(Shared.predictors(program.inner), &elem(&1, 0))

      {boot, execution} = bootstrap(program, neighbors, names, execution)
      labeled = labeled(program, neighbors, names, boot)

      demos =
        Map.new(names, fn name ->
          bootstrapped =
            Enum.take(Enum.reverse(Map.get(boot, name, [])), program.max_bootstrapped_demos)

          {name, bootstrapped ++ Map.get(labeled, name, [])}
        end)

      compiled = Shared.put_demos(program.inner, demos)
      Execution.call_program(execution, compiled, inputs)
    end
  end

  defp check_execution(execution) do
    cond do
      not Execution.has_role?(execution, :teacher) ->
        {:error,
         Error.Invalid.Option.exception(
           option: :teacher,
           message: "KNN programs need a teacher model configuration"
         ), execution}

      execution.max_model_calls == nil ->
        {:error,
         Error.Invalid.Option.exception(
           option: :max_model_calls,
           message: "KNN programs need an explicit call limit"
         ), execution}

      true ->
        :ok
    end
  end

  defp wrap({:ok, value}, _execution), do: {:ok, value}
  defp wrap({:error, error}, execution), do: {:error, error, execution}

  defp nearest(program, inputs, rows) do
    query = vector(program, inputs)

    rows
    |> Enum.with_index()
    |> Enum.map(fn {row, index} ->
      {similarity(query, vector(program, row["inputs"])), index, row}
    end)
    |> Enum.sort_by(fn {score, index, _row} -> {-score, index} end)
    |> Enum.take(program.k)
    |> Enum.map(fn {_score, _index, row} ->
      %Example{id: row["id"], inputs: row["inputs"], labels: row["labels"]}
    end)
  end

  defp bootstrap(program, neighbors, names, execution) do
    Enum.reduce(neighbors, {%{}, execution}, fn neighbor, {acc, execution} ->
      before = length(execution.steps)
      teacher = Shared.without_row_demos(program.inner, neighbor)

      case Execution.call_program(execution, teacher, neighbor.inputs,
             role: :teacher,
             scope: @scope
           ) do
        {:ok, _output, execution} ->
          new_steps =
            execution.steps |> Enum.take(length(execution.steps) - before) |> Enum.reverse()

          demos =
            new_steps
            |> Enum.map(&%{&1 | name: String.replace_prefix(&1.name, @scope <> ".", "")})
            |> then(&Shared.trajectory_demos(%Tune.Prediction{steps: &1}, names))

          {Enum.reduce(demos, acc, fn {name, demo}, acc ->
             Map.update(acc, name, [demo], &[demo | &1])
           end), execution}

        {:error, _error, execution} ->
          {acc, execution}
      end
    end)
  end

  defp labeled(%{max_labeled_demos: 0}, _neighbors, _names, _boot), do: %{}

  defp labeled(program, neighbors, names, boot) do
    predictors = Map.new(Shared.predictors(program.inner))

    Map.new(names, fn name ->
      used = length(Map.get(boot, name, []))

      demos =
        neighbors
        |> Enum.flat_map(fn example ->
          case Shared.labeled_demo(Map.fetch!(predictors, name), example) do
            {:ok, demo} -> [demo]
            :error -> []
          end
        end)
        |> Enum.take(
          max(program.max_labeled_demos - min(used, program.max_bootstrapped_demos), 0)
        )

      {name, demos}
    end)
  end

  defp vector(%__MODULE__{vectorizer: nil}, inputs), do: bag_of_words(inputs)

  defp vector(%__MODULE__{vectorizer: fun}, inputs) do
    case fun.(inputs) do
      list when is_list(list) -> list |> Enum.with_index() |> Map.new(fn {v, i} -> {i, v} end)
      map when is_map(map) -> map
    end
  end

  defp bag_of_words(inputs) do
    ~r/[[:alnum:]]+/u
    |> Regex.scan(inputs |> values_text() |> String.downcase())
    |> List.flatten()
    |> Enum.frequencies()
  end

  defp values_text(value) when is_map(value),
    do: value |> Enum.sort() |> Enum.map_join(" ", fn {_k, v} -> values_text(v) end)

  defp values_text(value) when is_list(value), do: Enum.map_join(value, " ", &values_text/1)
  defp values_text(value) when is_binary(value), do: value
  defp values_text(nil), do: ""
  defp values_text(value), do: to_string(value)

  defp pool_rows(_signature, []), do: {:ok, []}
  defp pool_rows(signature, rows), do: Example.normalize_all(signature, rows)

  defp similarity(left, right) do
    dot = Enum.reduce(left, 0, fn {key, value}, acc -> acc + value * Map.get(right, key, 0) end)
    norm = :math.sqrt(sum_squares(left)) * :math.sqrt(sum_squares(right))
    if norm == 0, do: 0.0, else: dot / norm
  end

  defp sum_squares(vector),
    do: Enum.reduce(vector, 0, fn {_key, value}, acc -> acc + value * value end)

  defp pool_parameter(signature, rows) do
    value =
      Enum.map(rows, fn row ->
        %{
          "id" => row.id,
          "inputs" => row.inputs,
          "labels" => Map.take(row.labels, Signature.output_names(signature))
        }
      end)

    Parameter.new(schema: pool_schema(signature), value: value, description: "KNN retrieval pool")
  end

  defp invalid(message), do: {:error, Error.Invalid.Definition.exception(message: message)}
end
