defmodule SymphonyElixir.Acp.TurnControl do
  @moduledoc false

  @spec permission_outcome(map(), boolean()) :: map()
  def permission_outcome(params, bypass_permissions) do
    options = Map.get(params, "options", [])

    selected_option =
      if bypass_permissions do
        select_permission_option(options, ["allow_always", "allow_once", "allow"])
      else
        select_permission_option(options, ["allow_once", "allow_always", "allow"])
      end ||
        select_permission_option(options, ["reject_once", "reject_always", "reject"])

    case selected_option do
      %{"optionId" => option_id} ->
        %{
          "outcome" => "selected",
          "optionId" => option_id
        }

      _ ->
        %{"outcome" => "cancelled"}
    end
  end

  @spec receive_timeout(integer(), integer() | :infinity) :: non_neg_integer()
  def receive_timeout(deadline_ms, stall_deadline_ms) do
    [
      milliseconds_until(deadline_ms),
      milliseconds_until(stall_deadline_ms)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> 0
      values -> Enum.min(values)
    end
  end

  @spec next_stall_deadline(non_neg_integer()) :: :infinity | integer()
  def next_stall_deadline(0), do: :infinity
  def next_stall_deadline(stall_timeout_ms), do: System.monotonic_time(:millisecond) + stall_timeout_ms

  @spec deadline_expired?(integer()) :: boolean()
  def deadline_expired?(deadline_ms) do
    System.monotonic_time(:millisecond) >= deadline_ms
  end

  @spec stall_expired?(integer() | :infinity) :: boolean()
  def stall_expired?(:infinity), do: false
  def stall_expired?(stall_deadline_ms), do: System.monotonic_time(:millisecond) >= stall_deadline_ms

  defp select_permission_option(options, preferred_kinds) when is_list(options) do
    Enum.find(options, fn option ->
      option_value = Map.get(option, "optionId") || Map.get(option, "kind")
      option_value in preferred_kinds and is_binary(Map.get(option, "optionId"))
    end)
  end

  defp milliseconds_until(:infinity), do: nil

  defp milliseconds_until(target_ms) when is_integer(target_ms) do
    max(target_ms - System.monotonic_time(:millisecond), 0)
  end
end
