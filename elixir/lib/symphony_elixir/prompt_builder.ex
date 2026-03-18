defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, McpSettings, MemoryBackend, SkillRuntime, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    workspace = Keyword.get(opts, :workspace)

    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    rendered_prompt =
      template
      |> Solid.render!(
        %{
          "attempt" => Keyword.get(opts, :attempt),
          "issue" => issue |> Map.from_struct() |> to_solid_map(),
          "memory" => issue |> MemoryBackend.prompt_context(workspace, opts) |> to_solid_map(),
          "skills" => issue |> SkillRuntime.prompt_context(workspace, opts) |> to_solid_map()
        },
        @render_opts
      )
      |> IO.iodata_to_binary()

    runtime_prelude(issue, workspace) <> rendered_prompt
  end

  defp runtime_prelude(issue, workspace) do
    sections =
      [
        tracker_runtime_context(issue),
        mcp_runtime_context(workspace)
      ]
      |> Enum.reject(&(&1 == nil or &1 == ""))

    case sections do
      [] -> ""
      _ -> Enum.join(sections, "\n") <> "\n\n"
    end
  end

  defp tracker_runtime_context(%{"id" => _issue_id} = issue), do: tracker_runtime_context(struct_issue(issue))

  defp tracker_runtime_context(%SymphonyElixir.Linear.Issue{id: issue_id, identifier: identifier}) do
    if Config.settings!().tracker.kind == "linear" and is_binary(issue_id) and issue_id != "" do
      """
      Runtime tracker context:

      - Internal Linear issue ID: #{issue_id}
      - Human Linear issue identifier: #{identifier}
      - Use the internal issue ID for tracker API calls and `sync_workpad(issue_id, file_path, comment_id?)`.
      - Symphony child sessions expose tracker auth through `LINEAR_API_TOKEN` and `LINEAR_API_KEY`; use the existing env and do not search for or mint new tokens.
      """
      |> String.trim()
    else
      ""
    end
  end

  defp tracker_runtime_context(_issue), do: ""

  defp mcp_runtime_context(workspace) do
    case McpSettings.loaded_server_names(workspace) do
      [] ->
        ""

      servers ->
        "Repo MCP servers loaded for this workspace: " <> Enum.join(servers, ", ")
    end
  end

  defp struct_issue(issue) when is_map(issue) do
    struct(SymphonyElixir.Linear.Issue, issue)
  rescue
    _error -> issue
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value
  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
