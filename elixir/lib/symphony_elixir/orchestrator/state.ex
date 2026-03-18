defmodule SymphonyElixir.Orchestrator.State do
  @moduledoc """
  Runtime state for the orchestrator polling loop.
  """

  @empty_codex_totals %{
    input_tokens: 0,
    cached_input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defstruct [
    :scheduler,
    :poll_interval_ms,
    :max_concurrent_agents,
    :next_poll_due_at_ms,
    :poll_check_in_progress,
    :tick_timer_ref,
    :tick_token,
    running: %{},
    completed: MapSet.new(),
    claimed: MapSet.new(),
    retry_attempts: %{},
    issue_input_token_totals: %{},
    issue_output_token_totals: %{},
    token_budget_exceeded: MapSet.new(),
    codex_totals: nil,
    codex_rate_limits: nil
  ]

  @type t :: %__MODULE__{}

  @spec new(map(), integer(), module()) :: t()
  def new(config, now_ms, scheduler)
      when is_map(config) and is_integer(now_ms) and is_atom(scheduler) do
    %__MODULE__{
      scheduler: scheduler,
      poll_interval_ms: config.polling.interval_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      codex_totals: @empty_codex_totals,
      codex_rate_limits: nil
    }
  end
end
