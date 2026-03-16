defmodule SymphonyElixir.ObservabilitySurface.Presenter do
  @moduledoc """
  Default observability surface adapter backed by the Phoenix presenter.
  """

  @behaviour SymphonyElixir.ObservabilitySurface

  alias SymphonyElixirWeb.Presenter

  @impl true
  def state_payload(orchestrator, snapshot_timeout_ms) do
    Presenter.state_payload(orchestrator, snapshot_timeout_ms)
  end

  @impl true
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) do
    Presenter.issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms)
  end

  @impl true
  def refresh_payload(orchestrator) do
    Presenter.refresh_payload(orchestrator)
  end
end
