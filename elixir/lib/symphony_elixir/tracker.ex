defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias SymphonyElixir.Config

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback project_summary() :: map()
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback fetch_active_workpad(String.t()) :: {:ok, map() | nil} | {:error, term()}
  @callback upsert_active_workpad(String.t(), String.t(), String.t() | nil) ::
              {:ok, map()} | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    adapter().fetch_candidate_issues()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    adapter().fetch_issue_states_by_ids(issue_ids)
  end

  @spec project_summary() :: map()
  def project_summary do
    adapter().project_summary()
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    adapter().create_comment(issue_id, body)
  end

  @spec fetch_active_workpad(String.t()) :: {:ok, map() | nil} | {:error, term()}
  def fetch_active_workpad(issue_id) do
    adapter().fetch_active_workpad(issue_id)
  end

  @spec upsert_active_workpad(String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def upsert_active_workpad(issue_id, body, comment_id \\ nil) do
    adapter().upsert_active_workpad(issue_id, body, comment_id)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    adapter().update_issue_state(issue_id, state_name)
  end

  @spec adapter() :: module()
  def adapter do
    case Application.get_env(:symphony_elixir, :tracker_module) do
      module when is_atom(module) and not is_nil(module) ->
        module

      _ ->
        case Config.settings!().tracker.kind do
          "memory" -> SymphonyElixir.Tracker.Memory
          "stub" -> SymphonyElixir.Tracker.Stub
          _ -> SymphonyElixir.Linear.Adapter
        end
    end
  end
end
