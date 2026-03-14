defmodule SymphonyElixir.AgentBackend.Claude do
  @moduledoc """
  Compatibility shim for legacy Claude backend references.
  """

  @behaviour SymphonyElixir.AgentBackend

  alias SymphonyElixir.AgentBackend.Acp

  @impl true
  def start_session(workspace, opts), do: Acp.start_session(workspace, opts)

  @impl true
  def run_turn(session, prompt, issue, opts), do: Acp.run_turn(session, prompt, issue, opts)

  @impl true
  def stop_session(session), do: Acp.stop_session(session)
end
