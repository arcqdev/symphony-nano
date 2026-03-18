defmodule SymphonyElixir.AcpClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Acp.Client

  test "ACP client initializes a session, auto-approves permissions, and completes a turn" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-acp-client-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-2001")
      acp_binary = Path.join(test_root, "fake-acp")
      trace_file = Path.join(test_root, "acp.trace")

      File.mkdir_p!(workspace)
      File.mkdir_p!(Path.join(workspace, ".claude"))

      File.write!(Path.join(workspace, ".claude/settings.json"), """
      {
        "mcpServers": {
          "paper": {
            "type": "http",
            "url": "http://127.0.0.1:29979/mcp"
          }
        }
      }
      """)

      File.write!(acp_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_ACP_TRACE:-/tmp/symphony-acp.trace}"
      prompt_request_id=""
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf '%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'
            ;;
          2)
            printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session-1","modes":{"availableModes":[{"id":"default"},{"id":"dontAsk"}]}}}'
            ;;
          3)
            prompt_request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
            printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-1","update":{"sessionUpdate":"plan","content":"thinking"}}}'
            printf '%s\\n' '{"jsonrpc":"2.0","id":"perm-1","method":"session/request_permission","params":{"sessionId":"session-1","options":[{"optionId":"allow_always"},{"optionId":"reject"}]}}'
            ;;
          4)
            printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"end_turn"}}\\n' "$prompt_request_id"
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(acp_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        acp_backends: %{
          "claude-code" => %{
            "command" => acp_binary,
            "env" => %{"SYMP_TEST_ACP_TRACE" => trace_file}
          }
        }
      )

      issue = %Issue{
        id: "issue-acp-client",
        identifier: "MT-2001",
        title: "Exercise ACP client",
        description: "Validate JSON-RPC flow",
        state: "In Progress",
        url: "https://example.org/issues/MT-2001",
        labels: ["frontend"]
      }

      assert {:ok, session} = Client.start_session(workspace, backend: "claude-code")
      assert session.workspace != workspace

      try do
        assert {:ok, result} =
                 Client.run_turn(
                   session,
                   "Make a tiny change",
                   issue,
                   on_message: fn message -> send(self(), {:acp_message, message}) end,
                   backend: "claude-code"
                 )

        assert result.backend == "claude-code"
        assert result.result == :turn_completed
        assert result.stop_reason == "end_turn"
        assert result.thread_id == "session-1"

        assert_receive {:acp_message, %{event: :session_started, backend: "claude-code", thread_id: "session-1"}}
        assert_receive {:acp_message, %{event: :notification, payload: %{"method" => "session/update"}}}

        assert_receive {:acp_message, %{event: :notification, payload: %{"method" => "session/request_permission"}}}

        assert_receive {:acp_message, %{event: :turn_completed, stop_reason: "end_turn"}}

        trace_payloads =
          trace_file
          |> File.read!()
          |> String.split("\n", trim: true)
          |> Enum.map(&Jason.decode!/1)

        assert Enum.any?(trace_payloads, fn payload ->
                 payload["method"] == "initialize" and
                   get_in(payload, ["params", "protocolVersion"]) == 1
               end)

        assert Enum.any?(trace_payloads, fn payload ->
                 payload["method"] == "session/new" and
                   get_in(payload, ["params", "cwd"]) == session.workspace and
                   get_in(payload, ["params", "mcpServers"]) == %{
                     "paper" => %{"url" => "http://127.0.0.1:29979/mcp"}
                   }
               end)

        assert Enum.any?(trace_payloads, fn payload ->
                 payload["method"] == "session/prompt" and
                   get_in(payload, ["params", "prompt"]) == [%{"type" => "text", "text" => "Make a tiny change"}]
               end)

        assert Enum.any?(trace_payloads, fn payload ->
                 payload["id"] == "perm-1" and
                   get_in(payload, ["result", "outcome", "outcome"]) == "selected" and
                   get_in(payload, ["result", "outcome", "optionId"]) == "allow_always"
               end)
      after
        Client.stop_session(session)
      end
    after
      File.rm_rf(test_root)
    end
  end

  test "ACP client surfaces missing commands as backend unavailable" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-acp-missing-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-2002")

      File.mkdir_p!(workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        acp_backends: %{
          "claude-code" => %{"command" => "definitely-not-a-real-acp-server"}
        }
      )

      assert {:error, {:backend_unavailable, "claude-code", {:port_exit, 127, _raw_output}}} =
               Client.start_session(workspace, backend: "claude-code")
    after
      File.rm_rf(test_root)
    end
  end

  test "ACP client applies stage model overrides from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-acp-stage-model-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-2003")
      acp_binary = Path.join(test_root, "fake-acp")
      trace_file = Path.join(test_root, "acp-stage-model.trace")

      File.mkdir_p!(workspace)

      File.write!(acp_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_ACP_TRACE:-/tmp/symphony-acp-stage-model.trace}"
      count=0
      config_request_id=""

      while IFS= read -r line; do
        count=$((count + 1))
        printf '%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'
            ;;
          2)
            printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session-2","configOptions":[{"id":"model","options":[{"value":"claude-sonnet"},{"value":"claude-haiku"}]}]}}'
            ;;
          3)
            config_request_id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
            printf '{"jsonrpc":"2.0","id":%s,"result":{}}\\n' "$config_request_id"
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(acp_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_stage_models: %{"frontend" => "claude-haiku"},
        acp_backends: %{
          "claude-code" => %{
            "command" => acp_binary,
            "env" => %{"SYMP_TEST_ACP_TRACE" => trace_file},
            "model" => "claude-sonnet"
          }
        }
      )

      assert {:ok, session} = Client.start_session(workspace, backend: "claude-code", stage: "frontend")

      Client.stop_session(session)

      trace_payloads =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      assert Enum.any?(trace_payloads, fn payload ->
               payload["method"] == "session/set_config_option" and
                 get_in(payload, ["params", "configId"]) == "model" and
                 get_in(payload, ["params", "value"]) == "claude-haiku"
             end)
    after
      File.rm_rf(test_root)
    end
  end
end
