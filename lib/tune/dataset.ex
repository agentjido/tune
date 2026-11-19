defmodule Tune.Dataset do
  @moduledoc false

  alias Tune.Error
  alias Tune.RunLimits

  @cleanup_timeout 100

  def factory(data, split) do
    case Map.fetch(data, split) do
      {:ok, factory} when is_function(factory, 0) ->
        {:ok, factory}

      {:ok, source} ->
        {:ok, fn -> source end}

      :error ->
        {:error,
         Error.Invalid.Option.exception(option: split, message: "#{split} data is required")}
    end
  end

  defp prefix(rows, nil), do: rows
  defp prefix(rows, limit), do: Stream.take(rows, limit)

  def snapshot(factory, split, limits, mode \\ :lookahead)

  def snapshot(_factory, split, %{cases: 0} = limits, _mode) do
    report(limits, split, :source, [])
    {:ok, [], true}
  end

  def snapshot(factory, split, limits, mode) do
    prepare = fn rows -> [select(rows, limits[:cases], mode)] end

    case reduce(factory, split, limits, prepare, nil, fn snapshot, _acc ->
           {:halt, snapshot}
         end) do
      {:ok, {rows, truncated?}} ->
        report(limits, split, :source, rows)
        {:ok, rows, truncated?}

      {:stopped, reason, _snapshot} ->
        {:stopped, reason}
    end
  end

  defp select(rows, limit, :prefix), do: {rows |> prefix(limit) |> Enum.to_list(), false}
  defp select(rows, nil, :lookahead), do: {Enum.to_list(rows), false}

  defp select(rows, limit, :lookahead) do
    {selected, extra} = rows |> lookahead(limit) |> Enum.split(limit)
    {selected, extra != []}
  end

  def reduce(factory, split, limits, prepare, acc, reducer) do
    case RunLimits.check(limits) do
      :ok -> read(factory, split, limits, prepare, acc, reducer)
      {:stopped, reason} -> {:stopped, reason, acc}
    end
  end

  defp read(factory, split, limits, prepare, acc, reducer) do
    {:ok, supervisor} = Task.Supervisor.start_link()
    owner = self()
    ref = make_ref()

    task =
      Task.Supervisor.async_nolink(supervisor, fn -> produce(owner, ref, factory, prepare) end)

    try do
      consume(task, ref, split, limits, acc, reducer)
    after
      Task.shutdown(task, :brutal_kill)
      Supervisor.stop(supervisor)

      receive do
        {^ref, _row} -> :ok
      after
        0 -> :ok
      end
    end
  end

  defp produce(owner, ref, factory, prepare) do
    receive do
      {^ref, :next} ->
        source = factory.()

        unless Enumerable.impl_for(source) do
          raise ArgumentError, "data must implement Enumerable"
        end

        source
        |> prepare.()
        |> Enum.reduce_while(:ok, fn row, :ok ->
          send(owner, {ref, row})

          receive do
            {^ref, :next} -> {:cont, :ok}
            {^ref, :halt} -> {:halt, :ok}
          end
        end)
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, %ErlangError{original: {kind, reason}}}
  end

  defp consume(task, ref, split, limits, acc, reducer) do
    case request(task, ref, limits) do
      {:row, row} ->
        case reduce_row(task, ref, limits, reducer, row, acc) do
          {:cont, acc} ->
            consume(task, ref, split, limits, acc, reducer)

          {:halt, acc} ->
            send(task.pid, {ref, :halt})
            finish(await(task, ref, limits), split, acc)
        end

      outcome ->
        finish(outcome, split, acc)
    end
  end

  defp reduce_row(task, ref, limits, reducer, row, acc) do
    reducer.(row, acc)
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__
      send(task.pid, {ref, :halt})
      Task.yield(task, min(@cleanup_timeout, RunLimits.remaining(limits[:expires_at])))
      :erlang.raise(kind, reason, stacktrace)
  end

  defp request(task, ref, limits) do
    with :ok <- RunLimits.check(limits) do
      send(task.pid, {ref, :next})
      await(task, ref, limits)
    end
  end

  defp await(%Task{ref: monitor} = task, ref, limits) do
    expires_at = limits[:expires_at]
    cancel = limits[:cancel]

    case RunLimits.stop_reason(expires_at, cancel) do
      nil ->
        timeout = expires_at |> RunLimits.remaining() |> RunLimits.wait_interval(cancel)

        receive do
          {^ref, row} ->
            {:row, row}

          {^monitor, result} ->
            result

          {:DOWN, ^monitor, :process, _pid, reason} ->
            {:error, %ErlangError{original: reason}}
        after
          timeout -> await(task, ref, limits)
        end

      reason ->
        {:stopped, reason}
    end
  end

  defp finish(:ok, _split, acc), do: {:ok, acc}
  defp finish({:stopped, reason}, _split, acc), do: {:stopped, reason, acc}

  defp finish({:error, error}, split, _acc),
    do: raise(Error.Invalid.Dataset, split: split, cause: error)

  def lookahead(rows, nil), do: rows
  def lookahead(rows, limit), do: prefix(rows, limit + 1)

  def split_chunk(chunk, nil), do: {chunk, false}

  def split_chunk(chunk, limit) do
    {selected, extra} = Enum.split_while(chunk, fn {_row, index} -> index < limit end)
    {selected, extra != []}
  end

  def report(%{on_dataset: callback}, split, stage, rows) when is_function(callback, 3) do
    callback.(split, stage, describe(rows))
    :ok
  end

  def report(_limits, _split, _stage, _rows), do: :ok

  defp describe(rows) do
    fingerprint =
      rows
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    %{rows: length(rows), fingerprint: fingerprint}
  end
end
