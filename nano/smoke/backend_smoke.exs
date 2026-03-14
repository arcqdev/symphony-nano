alias SymphonyElixir.{AgentBackend, Workflow}

defmodule Nano.BackendSmoke do
  @result_file "smoke.txt"

  def run do
    repo_root = Path.expand("../..", __DIR__)
    temp_root = Path.join(System.tmp_dir!(), "symphony-nano-backend-smoke-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(temp_root, "workspaces")
    workflow_path = Path.join(temp_root, "WORKFLOW.md")
    keep_workspace? = System.get_env("SYMPHONY_SMOKE_KEEP") == "1"

    codex_model = env("SYMPHONY_SMOKE_CODEX_MODEL", "gpt-5.1-codex-mini")
    claude_model = env("SYMPHONY_SMOKE_CLAUDE_MODEL", "haiku")

    claude_command =
      env(
        "SYMPHONY_SMOKE_CLAUDE_COMMAND",
        Path.join(repo_root, "nano/plugins/acp-claude/bin/acp-claude.mjs")
      )

    try do
      File.mkdir_p!(workspace_root)
      File.write!(workflow_path, workflow_content(workspace_root, codex_model, claude_command, claude_model))
      Workflow.set_workflow_file_path(workflow_path)
      {:ok, _started} = Application.ensure_all_started(:symphony_elixir)

      if Process.whereis(SymphonyElixir.WorkflowStore) do
        SymphonyElixir.WorkflowStore.force_reload()
      end

      backends = [
        %{name: "codex", expected: "codex smoke passed\n"},
        %{name: "claude-code", expected: "claude-code smoke passed\n"}
      ]

      results =
        Enum.map(backends, fn backend ->
          run_backend(workspace_root, backend)
        end)

      {:ok,
       %{
         ok: true,
         workflow_path: workflow_path,
         temp_root: temp_root,
         codex_model: codex_model,
         claude_model: claude_model,
         claude_command: claude_command,
         results: results
       }}
    rescue
      error ->
        {:error,
         %{
           ok: false,
           error: Exception.message(error),
           temp_root: temp_root,
           workflow_path: workflow_path
         }}
    after
      unless keep_workspace? do
        File.rm_rf!(temp_root)
      end
    end
  end

  defp run_backend(workspace_root, %{name: backend_name, expected: expected_contents}) do
    workspace = Path.join(workspace_root, backend_name)
    result_path = Path.join(workspace, @result_file)
    events_path = Path.join(workspace, "events.ndjson")
    File.mkdir_p!(workspace)
    File.write!(result_path, "pending\n")
    File.rm(events_path)

    issue = %{
      id: "smoke-#{backend_name}",
      identifier: "SMOKE-#{String.upcase(String.replace(backend_name, "-", "_"))}",
      title: "Backend smoke #{backend_name}",
      description: "Write one exact file and stop",
      labels: ["smoke"]
    }

    case AgentBackend.start_session(workspace, backend: backend_name) do
      {:ok, session} ->
        try do
          case AgentBackend.run_turn(
                 session,
                 backend_prompt(backend_name),
                 issue,
                 backend: backend_name,
                 on_message: fn message ->
                   File.write!(events_path, Jason.encode!(message) <> "\n", [:append])
                 end
               ) do
            {:ok, result} ->
              actual_contents = File.read!(result_path)

              if String.trim_trailing(actual_contents) != String.trim_trailing(expected_contents) do
                raise "unexpected smoke output for #{backend_name}: #{inspect(actual_contents)}"
              end

              %{
                backend: backend_name,
                result: result.result,
                stop_reason: result[:stop_reason],
                session_id: result[:session_id],
                result_path: result_path,
                events_path: events_path
              }

            {:error, reason} ->
              raise "backend #{backend_name} smoke failed: #{inspect(reason)}"
          end
        after
          AgentBackend.stop_session(session)
        end

      {:error, reason} ->
        raise "backend #{backend_name} startup failed: #{inspect(reason)}"
    end
  end

  defp backend_prompt(backend_name) do
    """
    You are running a backend smoke test.

    Only work inside the current directory.

    Replace the entire contents of `#{@result_file}` with exactly:
    #{backend_name} smoke passed

    Then verify the file by reading it back.

    Rules:
    - Do not create any other files.
    - Do not ask the user for anything.
    - Stop after `#{@result_file}` contains the exact required text.
    """
  end

  defp workflow_content(workspace_root, codex_model, claude_command, claude_model) do
    """
    ---
    tracker:
      kind: memory
    workspace:
      root: #{yaml_string(workspace_root)}
    agent:
      backend: "codex"
      max_concurrent_agents: 1
      max_turns: 1
    codex:
      command: "codex app-server"
      model: #{yaml_string(codex_model)}
      approval_policy: "never"
      thread_sandbox: "workspace-write"
      turn_timeout_ms: 120000
      read_timeout_ms: 5000
      stall_timeout_ms: 120000
    acp:
      turn_timeout_ms: 120000
      read_timeout_ms: 5000
      stall_timeout_ms: 120000
      bypass_permissions: true
      backends:
        claude-code:
          command: #{yaml_string(claude_command)}
          model: #{yaml_string(claude_model)}
          mode: "bypassPermissions"
    ---

    You are running a repo-local backend smoke test.
    """
  end

  defp yaml_string(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    ~s("#{escaped}")
  end

  defp env(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      value -> value
    end
  end
end

case Nano.BackendSmoke.run() do
  {:ok, payload} ->
    IO.puts(Jason.encode!(payload, pretty: true))
    System.halt(0)

  {:error, payload} ->
    IO.puts(Jason.encode!(payload, pretty: true))
    System.halt(1)
end
