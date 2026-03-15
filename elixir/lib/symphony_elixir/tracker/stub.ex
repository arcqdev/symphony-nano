defmodule SymphonyElixir.Tracker.Stub do
  @moduledoc """
  Deterministic local/training adapter for sidecar-style intake traffic.

  This adapter stores issue-like events in process-local application env state so tests can
  submit simulated inbound requests without external tracker credentials.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue

  @issue_key :stub_tracker_issues
  @comment_key :stub_tracker_issue_comments
  @recipient_key :stub_tracker_recipient

  @default_state "Todo"

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues, do: {:ok, issues_for_active_project()}

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = Enum.map(state_names, &normalize_state/1) |> MapSet.new()

    {:ok,
     Enum.filter(issues_for_active_project(), fn %Issue{state: state} ->
       normalize_state(state) in normalized_states
     end)}
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    requested_ids = MapSet.new(issue_ids)

    {:ok,
     issues_for_active_project()
     |> Enum.filter(fn %Issue{id: id} -> MapSet.member?(requested_ids, id) end)}
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    comments = Application.get_env(:symphony_elixir, @comment_key, %{})
    current = Map.get(comments, issue_id, [])
    updated = Map.put(comments, issue_id, [body | current])
    Application.put_env(:symphony_elixir, @comment_key, updated)
    send_event({:stub_tracker_comment, issue_id, body})
    :ok
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) when is_binary(issue_id) and is_binary(state_name) do
    case issue_by_id(issue_id) do
      %Issue{} = issue ->
        updated = %Issue{issue | state: state_name, updated_at: DateTime.utc_now()}
        persist_issue(updated)
        send_event({:stub_tracker_state_update, issue_id, state_name})
        :ok

      nil ->
        {:error, :missing_issue}
    end
  end

  @spec clear_for_test() :: :ok
  def clear_for_test do
    Application.put_env(:symphony_elixir, @issue_key, [])
    Application.put_env(:symphony_elixir, @comment_key, %{})
    :ok
  end

  @spec submit_intake_request(map()) :: {:ok, Issue.t()} | {:error, term()}
  def submit_intake_request(attrs) when is_map(attrs) do
    with {:ok, issue} <- normalize_request(attrs) do
      persist_issue(issue)
      {:ok, issue}
    end
  end

  @spec submit_request(map()) :: {:ok, Issue.t()} | {:error, term()}
  def submit_request(attrs), do: submit_intake_request(attrs)

  @spec issues_for_test() :: [Issue.t()]
  def issues_for_test, do: issues_for_active_project()

  @spec issue_for_test(String.t()) :: Issue.t() | nil
  def issue_for_test(issue_id) when is_binary(issue_id), do: issue_by_id(issue_id)

  @spec comments_for_test(String.t()) :: [String.t()]
  def comments_for_test(issue_id) when is_binary(issue_id) do
    Application.get_env(:symphony_elixir, @comment_key, %{})
    |> Map.get(issue_id, [])
    |> Enum.reverse()
  end

  @spec set_issue_state_for_test(String.t(), String.t()) :: :ok | {:error, term()}
  def set_issue_state_for_test(issue_id, state_name) when is_binary(issue_id) and is_binary(state_name),
    do: update_issue_state(issue_id, state_name)

  defp issues_for_active_project do
    configured_issues()
    |> Enum.filter(&issue_matches_configured_project?/1)
  end

  defp issue_matches_configured_project?(%Issue{project_slug: nil}), do: true

  defp issue_matches_configured_project?(%Issue{project_slug: issue_project_slug}) do
    configured_project = Config.settings!().tracker.project_slug

    is_nil(configured_project) or normalize_state(configured_project) == normalize_state(issue_project_slug)
  end

  defp issue_by_id(issue_id) when is_binary(issue_id) do
    issues_for_active_project()
    |> Enum.find(fn %Issue{id: id} -> id == issue_id end)
  end

  defp persist_issue(%Issue{} = issue) do
    issues = configured_issues()

    updated =
      [issue | Enum.reject(issues, fn %Issue{id: id} -> id == issue.id end)]
      |> Enum.sort_by(&issue_created_at_sort_key/1)

    Application.put_env(:symphony_elixir, @issue_key, updated)
    :ok
  end

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp configured_issues do
    Application.get_env(:symphony_elixir, @issue_key, [])
    |> Enum.map(&normalize_issue/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_issue(%Issue{} = issue), do: issue

  defp normalize_issue(values) when is_map(values) do
    case normalize_request(values) do
      {:ok, issue} -> issue
      _ -> nil
    end
  end

  defp normalize_issue(_value), do: nil

  defp normalize_request(attrs) when is_map(attrs) do
    issue_id = request_issue_id(attrs)
    identifier = resolve_identifier(attrs, issue_id)
    title = fetch_required_string(attrs, "title")

    with {:ok, id} <- issue_id,
         {:ok, normalized_identifier} <- identifier,
         {:ok, normalized_title} <- title do
      {:ok,
       %Issue{
         id: id,
         identifier: normalized_identifier,
         title: normalized_title,
         description: fetch_optional_string(attrs, "description"),
         state: fetch_string_with_default(attrs, "state", @default_state),
         priority: fetch_optional_integer(attrs, "priority"),
         project_slug: fetch_optional_string(attrs, "project_slug"),
         branch_name: fetch_optional_string(attrs, "branch_name"),
         url: fetch_optional_string(attrs, "url"),
         assignee_id: fetch_optional_string(attrs, "assignee_id"),
         labels: fetch_labels(attrs),
         blocked_by: fetch_blockers(attrs),
         created_at: fetch_datetime(attrs, "created_at"),
         updated_at: DateTime.utc_now()
       }}
    end
  end

  defp resolve_identifier(attrs, issue_id) do
    case fetch_required_string(attrs, "identifier", nil) do
      {:ok, identifier} -> {:ok, identifier}
      {:error, _} -> issue_id
    end
  end

  defp normalize_state(nil), do: ""

  defp normalize_state(state) when is_binary(state) do
    String.downcase(String.trim(state))
  end

  defp normalize_state(_state), do: ""

  defp fetch_labels(attrs) do
    case Map.get(attrs, :labels, Map.get(attrs, "labels")) do
      list when is_list(list) ->
        list
        |> Enum.map(&to_string/1)
        |> Enum.filter(&(to_string(&1) != ""))

      _ ->
        []
    end
  end

  defp fetch_blockers(attrs) do
    case Map.get(attrs, :blocked_by, Map.get(attrs, "blocked_by")) do
      list when is_list(list) ->
        Enum.map(list, &normalize_blocker/1)
        |> Enum.filter(&is_map/1)

      _ ->
        []
    end
  end

  defp normalize_blocker(values) when is_map(values) do
    state = Map.get(values, :state) || Map.get(values, "state")

    if is_binary(state) do
      %{state: state}
    else
      nil
    end
  end

  defp normalize_blocker(_value), do: nil

  defp fetch_datetime(attrs, key) do
    value = Map.get(attrs, String.to_atom(key), Map.get(attrs, key))

    cond do
      is_map(value) and match?(%DateTime{}, value) ->
        value

      is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, parsed_datetime, _offset} -> parsed_datetime
          {:error, _reason} -> nil
        end

      true ->
        nil
    end
  end

  defp fetch_required_string(attrs, key), do: fetch_required_string(attrs, key, nil)

  defp fetch_required_string(attrs, key, nil) do
    value = fetch_optional_string(attrs, key)

    case value do
      nil -> {:error, {:missing_required_field, key}}
      "" -> {:error, {:missing_required_field, key}}
      _ -> {:ok, value}
    end
  end

  defp fetch_required_string(attrs, key, fallback) when is_binary(fallback) do
    case fetch_required_string(attrs, key, nil) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> {:ok, fallback}
    end
  end

  defp fetch_optional_string(attrs, key) do
    value = Map.get(attrs, String.to_atom(key), Map.get(attrs, key))

    case value do
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  defp fetch_string_with_default(attrs, key, default) do
    case fetch_optional_string(attrs, key) do
      nil -> default
      value -> value
    end
  end

  defp fetch_optional_integer(attrs, key) do
    value = Map.get(attrs, String.to_atom(key), Map.get(attrs, key))

    if is_integer(value), do: value, else: nil
  end

  defp request_issue_id(attrs) do
    case fetch_required_string(attrs, "id", nil) do
      {:ok, value} ->
        {:ok, value}

      {:error, _reason} ->
        fetch_required_string(attrs, "identifier", nil)
    end
  end

  defp send_event(message) do
    case Application.get_env(:symphony_elixir, @recipient_key) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end
end
