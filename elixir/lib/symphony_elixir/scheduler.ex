defmodule SymphonyElixir.Scheduler do
  @moduledoc """
  Adapter boundary for retry and poll scheduling.
  """

  @type timer_ref :: reference()

  @callback send_after(pid(), term(), non_neg_integer()) :: timer_ref()
  @callback cancel_timer(timer_ref()) :: non_neg_integer() | false
  @callback monotonic_time(System.time_unit()) :: integer()

  @spec send_after(module(), pid(), term(), non_neg_integer()) :: timer_ref()
  def send_after(adapter, destination, message, delay_ms)
      when is_atom(adapter) and is_pid(destination) and is_integer(delay_ms) and delay_ms >= 0 do
    adapter.send_after(destination, message, delay_ms)
  end

  @spec cancel_timer(module(), timer_ref()) :: non_neg_integer() | false
  def cancel_timer(adapter, timer_ref) when is_atom(adapter) and is_reference(timer_ref) do
    adapter.cancel_timer(timer_ref)
  end

  @spec monotonic_time(module(), System.time_unit()) :: integer()
  def monotonic_time(adapter, unit) when is_atom(adapter) do
    adapter.monotonic_time(unit)
  end
end
