defmodule SymphonyElixir.AgentBackend.Codex do
  @moduledoc """
  Agent backend adapter that delegates to the Codex app-server (JSON-RPC 2.0 over stdio).
  """

  @behaviour SymphonyElixir.AgentBackend

  alias SymphonyElixir.Codex.AppServer

  @impl true
  def start_session(workspace, opts), do: AppServer.start_session(workspace, opts)

  @impl true
  def run_turn(session, prompt, issue, opts), do: AppServer.run_turn(session, prompt, issue, opts)

  @impl true
  def stop_session(session), do: AppServer.stop_session(session)
end
