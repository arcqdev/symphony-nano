defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{PathSafety, Tracker}

  @sync_workpad_tool "sync_workpad"
  @sync_workpad_description """
  Create or update the current issue's persistent workpad comment from a local markdown file.
  The file must live inside the current issue workspace so the tool payload stays small.
  """
  @sync_workpad_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["issue_id", "file_path"],
    "properties" => %{
      "issue_id" => %{
        "type" => "string",
        "description" => "Linear issue internal ID for the current issue."
      },
      "file_path" => %{
        "type" => "string",
        "description" => "Relative or absolute path to the markdown file to sync from."
      },
      "comment_id" => %{
        "type" => "string",
        "description" =>
          "Existing workpad comment ID to update. Omit to create or reuse the active workpad."
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @sync_workpad_tool ->
        execute_sync_workpad(arguments, opts)

      _other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @sync_workpad_tool,
        "description" => normalize_whitespace(@sync_workpad_description),
        "inputSchema" => @sync_workpad_input_schema
      }
    ]
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp success_response(payload) do
    dynamic_tool_response(true, encode_payload(payload))
  end

  defp execute_sync_workpad(arguments, opts) do
    with {:ok, issue_id, file_path, comment_id} <- normalize_sync_workpad_arguments(arguments),
         {:ok, body} <- read_workpad_file(file_path, opts),
         {:ok, workpad} <- Tracker.upsert_active_workpad(issue_id, body, comment_id) do
      success_response(%{
        "ok" => true,
        "workpad" => workpad
      })
    else
      {:error, reason} ->
        failure_response(sync_workpad_error_payload(reason))
    end
  end

  defp normalize_sync_workpad_arguments(arguments) when is_map(arguments) do
    issue_id = Map.get(arguments, "issue_id") || Map.get(arguments, :issue_id)
    file_path = Map.get(arguments, "file_path") || Map.get(arguments, :file_path)
    comment_id = Map.get(arguments, "comment_id") || Map.get(arguments, :comment_id)

    cond do
      not valid_non_empty_string?(issue_id) ->
        {:error, :missing_issue_id}

      not valid_non_empty_string?(file_path) ->
        {:error, :missing_file_path}

      valid_non_empty_string?(comment_id) ->
        {:ok, issue_id, file_path, comment_id}

      is_nil(comment_id) or comment_id == "" ->
        {:ok, issue_id, file_path, nil}

      true ->
        {:error, :invalid_comment_id}
    end
  end

  defp normalize_sync_workpad_arguments(_arguments), do: {:error, :invalid_arguments}

  defp read_workpad_file(path, opts) when is_binary(path) do
    workspace = Keyword.get(opts, :workspace)

    with {:ok, workspace_path} <- normalize_workspace(workspace),
         {:ok, candidate_path} <- resolve_workspace_path(path, workspace_path),
         {:ok, body} <- File.read(candidate_path),
         true <- String.trim(body) != "" do
      {:ok, body}
    else
      false ->
        {:error, {:file_empty, path}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_workspace(workspace) when is_binary(workspace) do
    PathSafety.canonicalize(workspace)
  end

  defp normalize_workspace(_workspace), do: {:error, :missing_workspace}

  defp resolve_workspace_path(path, workspace) do
    expanded_path =
      if Path.type(path) == :absolute do
        path
      else
        Path.expand(path, workspace)
      end

    with {:ok, canonical_path} <- PathSafety.canonicalize(expanded_path),
         true <- path_within_workspace?(canonical_path, workspace) do
      {:ok, canonical_path}
    else
      false ->
        {:error, {:file_outside_workspace, path}}

      {:error, {:path_canonicalize_failed, _path, :enoent}} ->
        {:error, {:file_missing, path}}

      {:error, {:path_canonicalize_failed, _path, reason}} ->
        {:error, {:file_unreadable, path, reason}}
    end
  end

  defp path_within_workspace?(path, workspace) do
    path == workspace or String.starts_with?(path <> "/", workspace <> "/")
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp sync_workpad_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "sync_workpad requires an object with `issue_id` and `file_path`."
      }
    }
  end

  defp sync_workpad_error_payload(:missing_issue_id) do
    %{"error" => %{"message" => "sync_workpad requires `issue_id`."}}
  end

  defp sync_workpad_error_payload(:missing_file_path) do
    %{"error" => %{"message" => "sync_workpad requires `file_path`."}}
  end

  defp sync_workpad_error_payload(:invalid_comment_id) do
    %{
      "error" => %{
        "message" => "sync_workpad `comment_id` must be a non-empty string when provided."
      }
    }
  end

  defp sync_workpad_error_payload(:missing_workspace) do
    %{"error" => %{"message" => "sync_workpad requires the current issue workspace."}}
  end

  defp sync_workpad_error_payload({:file_missing, path}) do
    %{"error" => %{"message" => "sync_workpad could not find `#{path}`."}}
  end

  defp sync_workpad_error_payload({:file_empty, path}) do
    %{"error" => %{"message" => "sync_workpad file is empty: `#{path}`."}}
  end

  defp sync_workpad_error_payload({:file_outside_workspace, path}) do
    %{
      "error" => %{
        "message" => "sync_workpad file must stay inside the current workspace: `#{path}`."
      }
    }
  end

  defp sync_workpad_error_payload({:file_unreadable, path, reason}) do
    %{
      "error" => %{
        "message" => "sync_workpad could not read `#{path}`: #{:file.format_error(reason)}."
      }
    }
  end

  defp sync_workpad_error_payload(reason) do
    %{"error" => %{"message" => "sync_workpad failed: #{inspect(reason)}."}}
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end

  defp normalize_whitespace(text) when is_binary(text) do
    text
    |> String.split()
    |> Enum.join(" ")
  end

  defp valid_non_empty_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp valid_non_empty_string?(_value), do: false
end
