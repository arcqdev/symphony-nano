defmodule SymphonyElixir.AgentBackend do
  @moduledoc """
  Adapter boundary for coding agent backends (Codex, Claude, etc.).
  """

  alias SymphonyElixir.Config

  @callback start_session(Path.t(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback run_turn(term(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback stop_session(term()) :: :ok

  @spec start_session(Path.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    adapter(Keyword.get(opts, :backend)).start_session(workspace, opts)
  end

  @spec run_turn(term(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []) do
    adapter(Keyword.get(opts, :backend)).run_turn(session, prompt, issue, opts)
  end

  @spec stop_session(term()) :: :ok
  def stop_session(session) do
    adapter(session_backend(session)).stop_session(session)
  end

  @spec adapter(String.t() | nil) :: module()
  def adapter(backend \\ nil) do
    case backend || Config.agent_backend() do
      "claude" -> SymphonyElixir.AgentBackend.Claude
      "claude-code" -> SymphonyElixir.AgentBackend.Claude
      _ -> SymphonyElixir.AgentBackend.Codex
    end
  end

  defp session_backend(%{backend: backend}) when is_binary(backend), do: backend
  defp session_backend(_session), do: nil
end
