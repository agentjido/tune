defmodule Tune.RunLimits do
  @moduledoc false

  def expiration(timeout) when is_integer(timeout),
    do: System.monotonic_time(:millisecond) + timeout

  def expiration(_timeout), do: nil

  def remaining(nil), do: :infinity
  def remaining(expires_at), do: max(expires_at - System.monotonic_time(:millisecond), 0)

  def check(limits) do
    case stop_reason(limits[:expires_at], limits[:cancel]) do
      nil -> :ok
      reason -> {:stopped, reason}
    end
  end

  def stop_reason(expires_at, cancel) do
    cond do
      cancel && cancel.() -> :cancelled
      remaining(expires_at) == 0 -> :deadline
      true -> nil
    end
  end

  def wait_interval(timeout, nil), do: timeout
  def wait_interval(timeout, _cancel), do: min(20, timeout)
end
