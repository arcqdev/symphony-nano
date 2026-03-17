defmodule SymphonyElixir.OrchestratorTokenBudgetTest do
  use SymphonyElixir.TestSupport

  test "token budget kills agent and moves issue to human review when input limit exceeded" do
    issue_id = "issue-token-budget"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-BUDGET",
      title: "Token budget test",
      description: "Test token budget enforcement",
      state: "In Progress",
      url: "https://example.org/issues/MT-BUDGET"
    }

    orchestrator_name = Module.concat(__MODULE__, :TokenBudgetOrchestrator)

    write_workflow_file!(Workflow.workflow_file_path(),
      max_input_tokens: 100,
      max_output_tokens: 50
    )

    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    agent_pid = spawn(fn -> Process.sleep(:infinity) end)
    process_ref = Process.monitor(agent_pid)

    running_entry = %{
      pid: agent_pid,
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: "session-budget-1",
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_app_server_pid: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      turn_count: 0,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "method" => "thread/tokenUsage/updated",
           "params" => %{
             "tokenUsage" => %{
               "total" => %{"input_tokens" => 150, "output_tokens" => 10, "total_tokens" => 160}
             }
           }
         },
         timestamp: DateTime.utc_now()
       }}
    )

    Process.sleep(50)
    mid_state = :sys.get_state(pid)
    assert MapSet.member?(mid_state.token_budget_exceeded, issue_id)
    refute Process.alive?(agent_pid)

    send(pid, {:DOWN, process_ref, :process, agent_pid, :killed})
    Process.sleep(50)

    state = :sys.get_state(pid)
    assert state.running == %{}
    assert MapSet.member?(state.completed, issue_id)
    refute MapSet.member?(state.claimed, issue_id)
    refute Map.has_key?(state.issue_input_token_totals, issue_id)
    refute Map.has_key?(state.issue_output_token_totals, issue_id)
  end

  test "token budget enforces output limit separately from input" do
    issue_id = "issue-output-budget"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-OBUDGET",
      title: "Output budget test",
      description: "Test output token budget",
      state: "In Progress",
      url: "https://example.org/issues/MT-OBUDGET"
    }

    orchestrator_name = Module.concat(__MODULE__, :OutputBudgetOrchestrator)

    write_workflow_file!(Workflow.workflow_file_path(),
      max_input_tokens: 10_000,
      max_output_tokens: 50
    )

    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    agent_pid = spawn(fn -> Process.sleep(:infinity) end)
    process_ref = Process.monitor(agent_pid)

    running_entry = %{
      pid: agent_pid,
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: "session-obudget-1",
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_app_server_pid: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      turn_count: 0,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "usage" => %{"input_tokens" => 20, "output_tokens" => 60, "total_tokens" => 80}
         },
         timestamp: DateTime.utc_now()
       }}
    )

    Process.sleep(50)
    mid_state = :sys.get_state(pid)
    assert MapSet.member?(mid_state.token_budget_exceeded, issue_id)
    refute Process.alive?(agent_pid)

    send(pid, {:DOWN, process_ref, :process, agent_pid, :killed})
    Process.sleep(50)

    state = :sys.get_state(pid)
    assert state.running == %{}
    assert MapSet.member?(state.completed, issue_id)
  end

  test "token budget accumulates across runs for the same issue" do
    issue_id = "issue-cumulative-budget"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-CUMUL",
      title: "Cumulative budget test",
      description: "Test cumulative token tracking",
      state: "In Progress",
      url: "https://example.org/issues/MT-CUMUL"
    }

    orchestrator_name = Module.concat(__MODULE__, :CumulativeBudgetOrchestrator)

    write_workflow_file!(Workflow.workflow_file_path(),
      max_input_tokens: 200,
      max_output_tokens: 100
    )

    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    state_with_prior = %{
      initial_state
      | issue_input_token_totals: Map.put(initial_state.issue_input_token_totals, issue_id, 120),
        issue_output_token_totals: Map.put(initial_state.issue_output_token_totals, issue_id, 30)
    }

    agent_pid = spawn(fn -> Process.sleep(:infinity) end)
    process_ref = Process.monitor(agent_pid)

    running_entry = %{
      pid: agent_pid,
      ref: process_ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: "session-cumul-2",
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_app_server_pid: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      turn_count: 0,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      state_with_prior
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(state_with_prior.claimed, issue_id))
    end)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         payload: %{
           "params" => %{
             "tokenUsage" => %{
               "total" => %{"input_tokens" => 90, "output_tokens" => 10, "total_tokens" => 100}
             }
           }
         },
         timestamp: DateTime.utc_now()
       }}
    )

    Process.sleep(50)
    mid_state = :sys.get_state(pid)
    assert MapSet.member?(mid_state.token_budget_exceeded, issue_id)
    refute Process.alive?(agent_pid)

    send(pid, {:DOWN, process_ref, :process, agent_pid, :killed})
    Process.sleep(50)

    state = :sys.get_state(pid)
    assert state.running == %{}
    assert MapSet.member?(state.completed, issue_id)
  end
end
