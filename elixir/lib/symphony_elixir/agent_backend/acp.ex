defmodule SymphonyElixir.AgentBackend.Acp do
  @moduledoc """
  Agent backend adapter for ACP-backed coding agents over stdio.
  """

  @behaviour SymphonyElixir.AgentBackend

  alias SymphonyElixir.Acp.Client

  @impl true
  def start_session(workspace, opts), do: Client.start_session(workspace, opts)

  @impl true
  def run_turn(session, prompt, issue, opts), do: Client.run_turn(session, prompt, issue, opts)

  @impl true
  def stop_session(session), do: Client.stop_session(session)
end
