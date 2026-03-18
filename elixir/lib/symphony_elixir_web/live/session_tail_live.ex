defmodule SymphonyElixirWeb.SessionTailLive do
  @moduledoc false

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.ObservabilitySurface
  alias SymphonyElixirWeb.Endpoint

  @runtime_tick_ms 1_000

  @impl true
  def mount(%{"session_id" => session_id}, _session, socket) do
    socket =
      socket
      |> assign(:session_id, session_id)
      |> assign(:payload, nil)
      |> assign(:status_message, nil)
      |> assign(:ended, false)

    socket =
      case load_session_payload(session_id) do
        {:ok, payload} ->
          assign(socket, payload: payload, ended: false, status_message: nil)

        {:error, _reason} ->
          assign(socket,
            payload: nil,
            ended: true,
            status_message: "Session not found or not currently running."
          )
      end

    if connected?(socket), do: schedule_runtime_tick()

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()

    socket =
      case load_session_payload(socket.assigns.session_id) do
        {:ok, payload} ->
          assign(socket, payload: payload, ended: false, status_message: nil)

        {:error, _reason} when is_nil(socket.assigns.payload) ->
          assign(socket, payload: nil, ended: true, status_message: "Session not found or not currently running.")

        {:error, _reason} ->
          assign(socket, ended: true, status_message: "Session completed.")
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Session Tail</p>
            <h1 class="hero-title"><%= tail_title(@payload, @session_id) %></h1>
            <p class="hero-copy">
              Full tail view for this running session.
            </p>
          </div>
          <div class="status-stack">
            <span class={"status-badge #{if @ended, do: "status-badge-offline", else: "status-badge-live"}"}>
              <span class="status-badge-dot"></span>
              <%= if @ended do %>Stopped<% else %>Live<% end %>
            </span>
          </div>
        </div>
      </header>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Output</h2>
            <p class="section-copy">Refreshes while the session is active.</p>
          </div>
          <p :if={@status_message} class="empty-state"><%= @status_message %></p>
        </div>
        <pre class="code-panel session-tail-log"><%= format_log_lines(@payload) %></pre>
      </section>
    </section>
    """
  end

  defp load_session_payload(session_id) do
    ObservabilitySurface.session_payload(session_id, orchestrator(), snapshot_timeout_ms())
  end

  defp tail_title(nil, session_id), do: session_id

  defp tail_title(%{issue_identifier: issue_identifier}, session_id)
       when is_binary(issue_identifier) and issue_identifier != "" do
    "#{issue_identifier} / #{session_id}"
  end

  defp tail_title(_payload, session_id), do: session_id

  defp format_log_lines(nil), do: "No log output available yet."

  defp format_log_lines(%{logs: %{codex_session_logs: lines}}) when is_list(lines),
    do: Enum.join(lines, "\n")

  defp format_log_lines(_payload), do: "No log output available yet."

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end
end
