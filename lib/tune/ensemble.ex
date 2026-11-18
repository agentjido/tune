defmodule Tune.Ensemble do
  @moduledoc """
  A program that runs compatible member programs and reduces their outputs.

  Members must declare the same input and output fields. Each run calls every
  member in order inside one execution, so all members share its call
  allowance, step limit, and deadline. Member parameters are exposed as
  `"m<index>.<name>"`, so artifacts load into a matching ensemble built by
  application code.

  The default reducer is a majority vote over canonical JSON outputs; ties go
  to the earliest member. A custom reducer is trusted application code that
  receives the ordered list of outputs and returns an output map or
  `{:ok, map}` / `{:error, reason}`.

  Construction makes no model calls. With `:size`, a seeded sample of that
  many members is kept, as DSPy's Ensemble does.
  """

  @behaviour Tune.Program

  alias Tune
  alias Tune.Error
  alias Tune.Execution
  alias Tune.Input

  @enforce_keys [:members, :reducer]
  defstruct [:members, :reducer]

  @type t :: %__MODULE__{
          members: [Tune.Program.t()],
          reducer: :majority | (list(map()) -> term())
        }

  @options Zoi.keyword(
             reducer:
               Zoi.union([Zoi.literal(:majority), Zoi.function(arity: 1)])
               |> Zoi.default(:majority),
             size: Zoi.integer() |> Zoi.positive() |> Zoi.nullable(),
             seed: Zoi.any() |> Zoi.default(0)
           )

  @doc """
  Builds an ensemble.

  Options: `:reducer` (`:majority` or a 1-arity function), `:size`, `:seed`.
  """
  @spec new([Tune.Program.t()], keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def new(members, opts \\ [])

  def new([first | _] = members, opts) do
    with {:ok, opts} <- Input.options(@options, opts, :ensemble, :first),
         {:ok, signature} <- Tune.Program.signature(first),
         :ok <- check_members(members, signature),
         {:ok, members} <- sample(members, opts[:size], opts[:seed]) do
      {:ok, %__MODULE__{members: members, reducer: opts[:reducer]}}
    end
  end

  def new(_members, _opts), do: invalid("an ensemble needs at least one member")

  @impl true
  def signature(%__MODULE__{members: [first | _]}) do
    {:ok, signature} = Tune.Program.signature(first)
    signature
  end

  @impl true
  def parameters(%__MODULE__{members: members}) do
    members
    |> Enum.with_index()
    |> Enum.flat_map(fn {member, index} ->
      {:ok, parameters} = Tune.Program.parameters(member)
      Enum.map(parameters, fn {name, value} -> {"m#{index}.#{name}", value} end)
    end)
    |> Map.new()
  end

  @impl true
  def put_parameters(%__MODULE__{members: members} = ensemble, parameters) do
    members =
      members
      |> Enum.with_index()
      |> Enum.map(fn {member, index} ->
        prefix = "m#{index}."

        updates =
          for {name, value} <- parameters, String.starts_with?(name, prefix), into: %{} do
            {String.replace_prefix(name, prefix, ""), value}
          end

        {:ok, member} = Tune.Program.replace_parameters(member, updates)
        member
      end)

    %{ensemble | members: members}
  end

  @impl true
  def call(%__MODULE__{members: members, reducer: reducer}, inputs, execution) do
    members
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], execution}, fn {member, index}, {:ok, outputs, execution} ->
      case Execution.call_program(execution, member, inputs, scope: "m#{index}") do
        {:ok, output, execution} -> {:cont, {:ok, [output | outputs], execution}}
        {:error, error, execution} -> {:halt, {:error, error, execution}}
      end
    end)
    |> case do
      {:ok, outputs, execution} -> reduce(reducer, Enum.reverse(outputs), execution)
      error -> error
    end
  end

  @doc "Majority vote with canonical equality; ties go to the earliest output."
  @spec majority([map()]) :: map()
  def majority(outputs) do
    counts = Enum.frequencies_by(outputs, &Tune.CanonicalJSON.encode!/1)
    top = counts |> Map.values() |> Enum.max()
    Enum.find(outputs, &(Map.fetch!(counts, Tune.CanonicalJSON.encode!(&1)) == top))
  end

  defp reduce(:majority, outputs, execution), do: {:ok, majority(outputs), execution}

  defp reduce(fun, outputs, execution) do
    case fun.(outputs) do
      {:ok, output} when is_map(output) -> {:ok, output, execution}
      {:error, reason} -> {:error, reducer_error(reason), execution}
      output when is_map(output) and not is_struct(output) -> {:ok, output, execution}
      other -> {:error, reducer_error(other), execution}
    end
  rescue
    error -> {:error, reducer_error(error), execution}
  end

  defp reducer_error(reason),
    do:
      Error.Execution.Callback.exception(
        message: "the ensemble reducer failed: #{inspect(reason)}",
        value: reason
      )

  defp check_members(members, signature) do
    Enum.reduce_while(members, :ok, fn member, :ok ->
      case Tune.Program.signature(member) do
        {:ok, other} ->
          if Tune.Program.same_fields?(signature, other),
            do: {:cont, :ok},
            else: {:halt, invalid("ensemble members must declare the same fields")}

        error ->
          {:halt, error}
      end
    end)
  end

  defp sample(members, nil, _seed), do: {:ok, members}

  defp sample(members, size, seed) when size <= length(members) do
    state = :rand.seed_s(:exsss, seed)

    {keyed, _state} =
      Enum.map_reduce(Enum.with_index(members), state, fn {member, index}, state ->
        {key, state} = :rand.uniform_s(state)
        {{key, index, member}, state}
      end)

    {:ok,
     keyed
     |> Enum.sort()
     |> Enum.take(size)
     |> Enum.sort_by(&elem(&1, 1))
     |> Enum.map(&elem(&1, 2))}
  end

  defp sample(_members, size, _seed),
    do:
      {:error,
       Error.Invalid.Option.exception(
         option: :size,
         message: "must be between 1 and the member count, got: #{size}"
       )}

  defp invalid(message), do: {:error, Error.Invalid.Definition.exception(message: message)}
end
