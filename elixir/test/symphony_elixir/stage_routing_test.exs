defmodule SymphonyElixir.StageRoutingTest do
  use SymphonyElixir.TestSupport

  defmodule RecordingBackend do
    @behaviour SymphonyElixir.AgentBackend

    @impl true
    def start_session(workspace, opts) do
      backend = Keyword.get(opts, :backend)
      stage = Keyword.get(opts, :stage)
      send(self(), {:backend_start, backend, stage, workspace})
      {:ok, %{backend: backend, stage: stage}}
    end

    @impl true
    def run_turn(session, prompt, _issue, opts) do
      send(self(), {:backend_turn, session.backend, session.stage, prompt})

      on_message = Keyword.fetch!(opts, :on_message)

      on_message.(%{
        event: :turn_completed,
        backend: session.backend,
        stage: session.stage,
        session_id: "#{session.backend}-#{session.stage}",
        timestamp: DateTime.utc_now()
      })

      {:ok, %{session_id: "#{session.backend}-#{session.stage}"}}
    end

    @impl true
    def stop_session(session) do
      send(self(), {:backend_stop, session.backend, session.stage})
      :ok
    end
  end

  defmodule UnavailableClaudeBackend do
    @behaviour SymphonyElixir.AgentBackend

    @impl true
    def start_session(workspace, opts) do
      backend = Keyword.get(opts, :backend)
      stage = Keyword.get(opts, :stage)
      send(self(), {:backend_start, backend, stage, workspace})

      case backend do
        "claude-code" -> {:error, {:backend_unavailable, "claude-code", :command_not_found}}
        _ -> {:ok, %{backend: backend, stage: stage}}
      end
    end

    @impl true
    def run_turn(session, prompt, _issue, opts) do
      send(self(), {:backend_turn, session.backend, session.stage, prompt})

      on_message = Keyword.fetch!(opts, :on_message)

      on_message.(%{
        event: :turn_completed,
        backend: session.backend,
        stage: session.stage,
        session_id: "#{session.backend}-#{session.stage}",
        timestamp: DateTime.utc_now()
      })

      {:ok, %{session_id: "#{session.backend}-#{session.stage}"}}
    end

    @impl true
    def stop_session(session) do
      send(self(), {:backend_stop, session.backend, session.stage})
      :ok
    end
  end

  defmodule RecordingTracker do
    def create_comment(issue_id, body) do
      send(self(), {:tracker_comment, issue_id, body})
      :ok
    end

    def update_issue_state(issue_id, state_name) do
      send(self(), {:tracker_state, issue_id, state_name})
      :ok
    end
  end

  test "config normalizes stage backend overrides and resolves routed stages" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_backend: "codex",
      agent_stage_backends: %{"frontend" => "claude", "integration" => "codex"}
    )

    assert Config.settings!().agent.stage_backends == %{
             "frontend" => "claude-code",
             "integration" => "codex"
           }

    assert Config.backend_for_stage("frontend") == "claude-code"
    assert Config.backend_for_stage("backend") == "codex"

    issue = %Issue{
      id: "issue-routes",
      identifier: "MT-701",
      title: "Mixed routing",
      description: "Exercise stage routing",
      state: "In Progress",
      labels: ["integration", "frontend", "backend"]
    }

    assert Config.routed_stages(issue) == [
             %{stage: "backend", backend: "codex"},
             %{stage: "frontend", backend: "claude-code"},
             %{stage: "integration", backend: "codex"}
           ]
  end

  test "config rejects invalid stage backend overrides" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_stage_backends: %{"frontend" => "mystery-backend"}
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.stage_backends"
  end

  test "config accepts configured ACP backends in stage routing" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_backend: "review-bot",
      agent_stage_backends: %{"frontend" => "review-bot"},
      acp_backends: %{
        "claude-code" => %{"command" => "claude-agent-acp"},
        "review-bot" => %{"command" => "custom-review-acp"}
      }
    )

    assert Config.validate!() == :ok
    assert Config.agent_backend() == "review-bot"
    assert Config.backend_for_stage("frontend") == "review-bot"
    assert Config.settings!().acp.backends["review-bot"]["command"] == "custom-review-acp"
  end

  test "agent runner routes labeled stages through configured backends and emits backend metadata" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-stage-routing-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(workspace_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_backend: "codex",
      agent_stage_backends: %{"frontend" => "claude-code"}
    )

    issue = %Issue{
      id: "issue-stage-runner",
      identifier: "MT-702",
      title: "Stage runner routing",
      description: "Route mixed-stage issues through different backends",
      state: "In Progress",
      labels: ["frontend", "backend", "integration"]
    }

    assert :ok =
             AgentRunner.run(
               issue,
               self(),
               agent_backend: RecordingBackend,
               issue_state_fetcher: fn _issue_ids -> {:ok, []} end
             )

    assert_receive {:backend_start, "codex", "backend", _workspace}
    assert_receive {:backend_turn, "codex", "backend", backend_prompt}
    assert backend_prompt =~ "Current stage: backend"
    assert backend_prompt =~ "Do not perform other stages or final landing in this turn."
    assert_receive {:backend_stop, "codex", "backend"}

    assert_receive {:backend_start, "claude-code", "frontend", _workspace}
    assert_receive {:backend_turn, "claude-code", "frontend", frontend_prompt}
    assert frontend_prompt =~ "Current stage: frontend"
    assert frontend_prompt =~ "Do not perform other stages or final landing in this turn."
    assert_receive {:backend_stop, "claude-code", "frontend"}

    assert_receive {:backend_start, "codex", "integration", _workspace}
    assert_receive {:backend_turn, "codex", "integration", integration_prompt}
    assert integration_prompt =~ "Current stage: integration"
    assert integration_prompt =~ "complete Stage 3 validation and landing"
    assert_receive {:backend_stop, "codex", "integration"}

    assert_receive {:worker_runtime_info, "issue-stage-runner", %{backend: "codex", stage: "backend", workspace_path: _workspace}}

    assert_receive {:codex_worker_update, "issue-stage-runner", %{event: :turn_completed, backend: "codex", stage: "backend"}}

    assert_receive {:codex_worker_update, "issue-stage-runner", %{event: :turn_completed, backend: "claude-code", stage: "frontend"}}

    assert_receive {:codex_worker_update, "issue-stage-runner", %{event: :turn_completed, backend: "codex", stage: "integration"}}
  end

  test "agent runner moves issue to Rework when claude backend is unavailable for a routed stage" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-stage-routing-blocked-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(workspace_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_backend: "codex",
      agent_stage_backends: %{"frontend" => "claude-code"}
    )

    issue = %Issue{
      id: "issue-stage-blocked",
      identifier: "MT-703",
      title: "Frontend blocked",
      description: "Fail clearly when Claude is unavailable",
      state: "In Progress",
      labels: ["frontend"]
    }

    assert :ok =
             AgentRunner.run(
               issue,
               self(),
               agent_backend: UnavailableClaudeBackend,
               tracker: RecordingTracker,
               issue_state_fetcher: fn _issue_ids -> {:ok, []} end
             )

    assert_receive {:backend_start, "claude-code", "frontend", _workspace}

    assert_receive {:tracker_comment, "issue-stage-blocked", body}
    assert body =~ "claude-code"
    assert body =~ "frontend"
    assert body =~ "Rework"

    assert_receive {:tracker_state, "issue-stage-blocked", "Rework"}

    assert_receive {:codex_worker_update, "issue-stage-blocked", %{event: :backend_unavailable, backend: "claude-code", stage: "frontend"}}

    refute_received {:backend_start, "codex", _, _}
  end
end
