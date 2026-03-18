defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Client

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
      comment {
        id
        body
        createdAt
        updatedAt
        resolvedAt
        url
      }
    }
  }
  """

  @workpad_lookup_query """
  query SymphonyActiveWorkpad($issueId: String!) {
    issue(id: $issueId) {
      comments(first: 50) {
        nodes {
          id
          body
          createdAt
          updatedAt
          resolvedAt
          url
        }
      }
    }
  }
  """

  @update_workpad_mutation """
  mutation SymphonyUpdateComment($commentId: String!, $body: String!) {
    commentUpdate(id: $commentId, input: {body: $body}) {
      success
      comment {
        id
        body
        createdAt
        updatedAt
        resolvedAt
        url
      }
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids),
    do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec project_summary() :: map()
  def project_summary, do: client_module().project_summary()

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <-
           client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec fetch_active_workpad(String.t()) :: {:ok, map() | nil} | {:error, term()}
  def fetch_active_workpad(issue_id) when is_binary(issue_id) do
    with {:ok, response} <- client_module().graphql(@workpad_lookup_query, %{issueId: issue_id}) do
      case get_in(response, ["data", "issue", "comments", "nodes"]) do
        comments when is_list(comments) ->
          {:ok, Enum.find(comments, &active_workpad_comment?/1)}

        _ ->
          {:error, :workpad_lookup_failed}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec upsert_active_workpad(String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def upsert_active_workpad(issue_id, body, comment_id \\ nil)
      when is_binary(issue_id) and is_binary(body) do
    with {:ok, existing_comment_id} <- resolve_workpad_comment_id(issue_id, comment_id),
         {:ok, response} <- upsert_workpad_request(issue_id, body, existing_comment_id),
         {:ok, workpad} <- decode_upsert_workpad_response(response, existing_comment_id) do
      {:ok, workpad}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp resolve_workpad_comment_id(_issue_id, comment_id)
       when is_binary(comment_id) and comment_id != "" do
    {:ok, comment_id}
  end

  defp resolve_workpad_comment_id(issue_id, _comment_id) do
    case fetch_active_workpad(issue_id) do
      {:ok, %{"id" => existing_comment_id}} when is_binary(existing_comment_id) ->
        {:ok, existing_comment_id}

      {:ok, nil} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp upsert_workpad_request(issue_id, body, nil) do
    client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body})
  end

  defp upsert_workpad_request(_issue_id, body, comment_id) do
    client_module().graphql(@update_workpad_mutation, %{commentId: comment_id, body: body})
  end

  defp decode_upsert_workpad_response(response, nil) do
    case get_in(response, ["data", "commentCreate"]) do
      %{"success" => true, "comment" => %{} = comment} -> {:ok, comment}
      _ -> {:error, :workpad_upsert_failed}
    end
  end

  defp decode_upsert_workpad_response(response, _comment_id) do
    case get_in(response, ["data", "commentUpdate"]) do
      %{"success" => true, "comment" => %{} = comment} -> {:ok, comment}
      _ -> {:error, :workpad_upsert_failed}
    end
  end

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{
             issueId: issue_id,
             stateName: state_name
           }),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end

  defp active_workpad_comment?(comment) when is_map(comment) do
    body = Map.get(comment, "body")
    resolved_at = Map.get(comment, "resolvedAt")

    is_binary(body) and String.contains?(body, "## Codex Workpad") and is_nil(resolved_at)
  end
end
