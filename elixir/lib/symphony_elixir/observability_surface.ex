defmodule SymphonyElixir.ObservabilitySurface do
  @moduledoc """
  Adapter boundary for operator-facing observability payloads.
  """

  @callback state_payload(GenServer.name(), timeout()) :: map()
  @callback issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  @callback session_payload(String.t(), GenServer.name(), timeout()) ::
              {:ok, map()} | {:error, :session_not_found}
  @callback refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}

  @spec state_payload(GenServer.name(), timeout(), keyword()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms, opts \\ []) do
    adapter(opts).state_payload(orchestrator, snapshot_timeout_ms)
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout(), keyword()) ::
          {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms, opts \\ []) do
    adapter(opts).issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms)
  end

  @spec session_payload(String.t(), GenServer.name(), timeout(), keyword()) ::
          {:ok, map()} | {:error, :session_not_found}
  def session_payload(session_id, orchestrator, snapshot_timeout_ms, opts \\ []) do
    adapter(opts).session_payload(session_id, orchestrator, snapshot_timeout_ms)
  end

  @spec refresh_payload(GenServer.name(), keyword()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator, opts \\ []) do
    adapter(opts).refresh_payload(orchestrator)
  end

  defp adapter(opts) do
    Keyword.get(opts, :observability_surface, SymphonyElixir.ObservabilitySurface.Presenter)
  end
end
