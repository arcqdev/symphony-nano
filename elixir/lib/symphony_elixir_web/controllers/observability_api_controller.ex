defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixirWeb.{Endpoint, Presenter}
  alias SymphonyElixir.Tracker.Stub

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec stub_intake(Conn.t(), map()) :: Conn.t()
  def stub_intake(conn, _params) do
    with :ok <- ensure_stub_mode(),
         {:ok, submit_params} <- decode_stub_payload(conn),
         {:ok, issue} <- Stub.submit_intake_request(submit_params) do
      conn
      |> put_status(202)
      |> json(%{
        "status" => "accepted",
        "issue_id" => issue.id,
        "issue_identifier" => issue.identifier
      })
    else
      :error_not_stub ->
        error_response(conn, 409, "unsupported_tracker", "Tracker kind is not stub")

      {:error, {:missing_required_field, field}} ->
        error_response(conn, 422, "missing_field", "Missing required field: #{field}")

      {:error, {:invalid_payload, reason}} ->
        error_response(conn, 400, "invalid_payload", inspect(reason))

      {:error, reason} ->
        error_response(conn, 400, "bad_request", inspect(reason))
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp ensure_stub_mode do
    config = SymphonyElixir.Config.settings!()

    if config.tracker.kind == "stub" do
      :ok
    else
      :error_not_stub
    end
  end

  defp decode_stub_payload(%Conn{params: params}) when is_map(params), do: {:ok, params}

  defp decode_stub_payload(%Conn{}) do
    {:error, {:invalid_payload, :missing_map}}
  end
end
