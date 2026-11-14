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

  @behaviour Tune

  alias Tune
  alias Tune.Error
  alias Tune.Example
  alias Tune.Execution

  @enforce_keys [:members, :reducer]
  defstruct [:members, :reducer]

  @type t :: %__MODULE__{members: [Tune.t()], reducer: :majority | (list(map()) -> term())}

  @doc """
  Builds an ensemble.

  Options: `:reducer` (`:majority` or a 1-arity function), `:size`, `:seed`.
  """
  @spec new([Tune.t()], keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def new(members, opts \\ [])

  def new([first | _] = members, opts) do
    reducer = Keyword.get(opts, :reducer, :majority)

    with :ok <- check_reducer(reducer),
         {:ok, signature} <- Tune.signature(first),
         :ok <- check_members(members, signature),
         {:ok, members} <- sample(members, opts) do
      {:ok, %__MODULE__{members: members, reducer: reducer}}
    end
  end

  def new(_members, _opts), do: invalid("an ensemble needs at least one member")

  @impl true
  def signature(%__MODULE__{members: [first | _]}) do
    {:ok, signature} = Tune.signature(first)
    signature
  end

  @impl true
  def parameters(%__MODULE__{members: members}) do
    members
    |> Enum.with_index()
    |> Enum.flat_map(fn {member, index} ->
      {:ok, parameters} = Tune.parameters(member)
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

        {:ok, member} = Tune.replace_parameters(member, updates)
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
    counts = Enum.frequencies_by(outputs, &Example.canonical_json/1)
    top = counts |> Map.values() |> Enum.max()
    Enum.find(outputs, &(Map.fetch!(counts, Example.canonical_json(&1)) == top))
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

  defp check_reducer(:majority), do: :ok
  defp check_reducer(fun) when is_function(fun, 1), do: :ok

  defp check_reducer(other),
    do:
      {:error,
       Error.Invalid.Option.exception(
         option: :reducer,
         message: "must be :majority or a 1-arity function, got: #{inspect(other)}"
       )}

  defp check_members(members, signature) do
    Enum.reduce_while(members, :ok, fn member, :ok ->
      case Tune.signature(member) do
        {:ok, other} ->
          if Tune.same_fields?(signature, other),
            do: {:cont, :ok},
            else: {:halt, invalid("ensemble members must declare the same fields")}

        error ->
          {:halt, error}
      end
    end)
  end

  defp sample(members, opts) do
    case Keyword.get(opts, :size) do
      nil ->
        {:ok, members}

      size when is_integer(size) and size > 0 and size <= length(members) ->
        state = :rand.seed_s(:exsss, Keyword.get(opts, :seed, 0))

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

      other ->
        {:error,
         Error.Invalid.Option.exception(
           option: :size,
           message: "must be between 1 and the member count, got: #{inspect(other)}"
         )}
    end
  end

  defp invalid(message), do: {:error, Error.Invalid.Definition.exception(message: message)}
end
