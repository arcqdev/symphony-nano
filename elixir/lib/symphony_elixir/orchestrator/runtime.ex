defmodule SymphonyElixir.Orchestrator.Runtime do
  @moduledoc false

  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{Config, Tracker, Workspace}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.{CodexTracking, Dispatch, State}

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000

  @spec run_terminal_workspace_cleanup() :: :ok
  def run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{identifier: identifier} when is_binary(identifier) ->
            cleanup_issue_workspace(identifier)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning(
          "Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}"
        )
    end

    :ok
  end

  @spec schedule_issue_retry(State.t(), String.t(), integer() | nil, map()) :: State.t()
  def schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
      when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)
    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning(
      "Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms " <>
        "(attempt #{next_attempt})#{error_suffix}"
    )

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            identifier: identifier,
            error: error,
            worker_host: worker_host,
            workspace_path: workspace_path
          })
    }
  end

  @spec pop_retry_attempt_state(State.t(), String.t(), reference()) ::
          {:ok, integer(), map(), State.t()} | :missing
  def pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  @spec handle_retry_issue(State.t(), String.t(), integer(), map()) :: {:noreply, State.t()}
  def handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning(
          "Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: " <>
            "#{inspect(reason)}"
        )

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  @spec cleanup_issue_workspace(term(), String.t() | nil) :: :ok | term()
  def cleanup_issue_workspace(identifier, worker_host \\ nil)

  def cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  def cleanup_issue_workspace(_identifier, _worker_host), do: :ok

  @spec release_issue_claim(State.t(), String.t()) :: State.t()
  def release_issue_claim(%State{} = state, issue_id) do
    %{state | claimed: MapSet.delete(state.claimed, issue_id)}
    |> CodexTracking.clear_issue_token_totals(issue_id)
  end

  @spec maybe_put_runtime_value(map(), atom(), term()) :: map()
  def maybe_put_runtime_value(running_entry, _key, nil), do: running_entry
  def maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry), do: Map.put(running_entry, key, value)

  @spec normalize_retry_attempt(integer() | term()) :: integer()
  def normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  def normalize_retry_attempt(_attempt), do: 0

  @spec next_retry_attempt_from_running(map()) :: integer() | nil
  def next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = Dispatch.terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info(
          "Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} " <>
            "state=#{issue.state}; removing associated workspace"
        )

        cleanup_issue_workspace(issue.identifier, metadata[:worker_host])
        {:noreply, release_issue_claim(state, issue_id)}

      Dispatch.retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug(
          "Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}"
        )

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    if Dispatch.retry_candidate_issue?(issue, Dispatch.terminal_state_set()) and
         Dispatch.dispatch_slots_available?(issue, state) and
         Dispatch.worker_slots_available?(state, metadata[:worker_host]) do
      {:noreply, Dispatch.dispatch_issue(state, issue, attempt, metadata[:worker_host], self(), &schedule_issue_retry/4)}
    else
      Logger.debug("No available slots for retrying #{Dispatch.issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt + 1,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           error: "no available orchestrator slots"
         })
       )}
    end
  end

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    normalized_state = String.downcase(String.trim(state_name))
    MapSet.member?(terminal_states, normalized_state)
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] == :continuation and attempt == 1 do
      @continuation_retry_delay_ms
    else
      failure_retry_delay(attempt)
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.settings!().agent.max_retry_backoff_ms)
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} -> true
      _ -> false
    end)
  end
end
