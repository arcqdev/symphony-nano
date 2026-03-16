defmodule SymphonyElixir.Scheduler.System do
  @moduledoc """
  Default scheduler adapter backed by BEAM timers and monotonic time.
  """

  @behaviour SymphonyElixir.Scheduler

  @impl true
  def send_after(destination, message, delay_ms) do
    Process.send_after(destination, message, delay_ms)
  end

  @impl true
  def cancel_timer(timer_ref) do
    Process.cancel_timer(timer_ref)
  end

  @impl true
  def monotonic_time(unit) do
    System.monotonic_time(unit)
  end
end
