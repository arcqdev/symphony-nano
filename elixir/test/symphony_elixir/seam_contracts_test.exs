defmodule SymphonyElixir.SeamContractsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Linear.Issue, MemoryBackend, ObservabilitySurface, Orchestrator, PromptBuilder, Scheduler, SkillRuntime}

  defmodule RecordingMemoryBackend do
    @behaviour SymphonyElixir.MemoryBackend

    def prompt_context(issue, workspace, _opts) do
      send(Application.fetch_env!(:symphony_elixir, :seam_contracts_test_recipient), {:memory_backend, issue.identifier, workspace})
      {:ok, %{present: true, summary: "memory:#{issue.identifier}"}}
    end
  end

  defmodule RecordingSkillRuntime do
    @behaviour SymphonyElixir.SkillRuntime

    def prompt_context(issue, workspace, _opts) do
      send(Application.fetch_env!(:symphony_elixir, :seam_contracts_test_recipient), {:skill_runtime, issue.identifier, workspace})
      {:ok, %{present: true, entries: [%{name: "status", workspace: workspace}]}}
    end
  end

  defmodule RecordingObservabilitySurface do
    @behaviour SymphonyElixir.ObservabilitySurface

    def state_payload(orchestrator, snapshot_timeout_ms) do
      %{orchestrator: orchestrator, snapshot_timeout_ms: snapshot_timeout_ms}
    end

    def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) do
      {:ok, %{issue_identifier: issue_identifier, orchestrator: orchestrator, snapshot_timeout_ms: snapshot_timeout_ms}}
    end

    def session_payload(session_id, orchestrator, snapshot_timeout_ms) do
      {:ok, %{session_id: session_id, orchestrator: orchestrator, snapshot_timeout_ms: snapshot_timeout_ms}}
    end

    def refresh_payload(orchestrator) do
      {:ok, %{queued: true, orchestrator: orchestrator}}
    end
  end

  defmodule RecordingScheduler do
    @behaviour SymphonyElixir.Scheduler

    def send_after(destination, message, delay_ms) do
      send(recipient(), {:scheduler_send_after, destination, message, delay_ms})
      make_ref()
    end

    def cancel_timer(timer_ref) do
      send(recipient(), {:scheduler_cancel_timer, timer_ref})
      Process.cancel_timer(timer_ref)
    end

    def monotonic_time(unit) do
      value = System.monotonic_time(unit)
      send(recipient(), {:scheduler_monotonic_time, unit, value})
      value
    end

    defp recipient do
      Application.fetch_env!(:symphony_elixir, :seam_contracts_test_recipient)
    end
  end

  setup do
    Application.put_env(:symphony_elixir, :seam_contracts_test_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :seam_contracts_test_recipient)
    end)

    :ok
  end

  test "prompt builder pulls optional memory and skill runtime context through named seams" do
    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: """
      Issue {{ issue.identifier }}
      Memory present={{ memory.present }} summary={{ memory.summary }}
      Skills present={{ skills.present }} first={{ skills.entries[0].name }}
      """
    )

    issue = %Issue{id: "issue-seams", identifier: "ARC-62", title: "Seam test"}
    workspace = "/tmp/arc-62"

    prompt =
      PromptBuilder.build_prompt(issue,
        workspace: workspace,
        memory_backend: RecordingMemoryBackend,
        skill_runtime: RecordingSkillRuntime
      )

    assert_receive {:memory_backend, "ARC-62", ^workspace}
    assert_receive {:skill_runtime, "ARC-62", ^workspace}
    assert prompt =~ "Memory present=true summary=memory:ARC-62"
    assert prompt =~ "Skills present=true first=status"
  end

  test "observability surface delegates payload building through an adapter boundary" do
    assert ObservabilitySurface.state_payload(:orch, 25, observability_surface: RecordingObservabilitySurface) ==
             %{orchestrator: :orch, snapshot_timeout_ms: 25}

    assert ObservabilitySurface.issue_payload("ARC-62", :orch, 50, observability_surface: RecordingObservabilitySurface) ==
             {:ok, %{issue_identifier: "ARC-62", orchestrator: :orch, snapshot_timeout_ms: 50}}

    assert ObservabilitySurface.session_payload("session-1", :orch, 90, observability_surface: RecordingObservabilitySurface) ==
             {:ok, %{session_id: "session-1", orchestrator: :orch, snapshot_timeout_ms: 90}}

    assert ObservabilitySurface.refresh_payload(:orch, observability_surface: RecordingObservabilitySurface) ==
             {:ok, %{queued: true, orchestrator: :orch}}
  end

  test "orchestrator uses the scheduler seam for poll and retry timing" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    orchestrator_name = Module.concat(__MODULE__, :RecordingSchedulerOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name, scheduler: RecordingScheduler)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    assert_receive {:scheduler_monotonic_time, :millisecond, _}
    assert_receive {:scheduler_send_after, ^pid, {:tick, tick_token}, 0}

    send(pid, {:tick, tick_token})
    assert_receive {:scheduler_send_after, ^pid, :run_poll_cycle, 20}

    issue_id = "issue-retry"
    ref = make_ref()

    :sys.replace_state(pid, fn state ->
      running =
        Map.put(state.running, issue_id, %{
          pid: self(),
          ref: ref,
          identifier: "ARC-62",
          issue: %Issue{id: issue_id, identifier: "ARC-62", title: "Retry seam"},
          worker_host: nil,
          workspace_path: "/tmp/arc-62",
          session_id: nil,
          retry_attempt: 0,
          started_at: DateTime.utc_now()
        })

      %{state | running: running}
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})

    assert_receive {:scheduler_send_after, ^pid, {:retry_issue, ^issue_id, _retry_token}, 10_000}
  end

  test "scheduler wrapper delegates directly to the selected adapter" do
    me = self()
    timer_ref = Scheduler.send_after(RecordingScheduler, self(), :hello, 5)

    assert is_reference(timer_ref)
    assert_receive {:scheduler_send_after, ^me, :hello, 5}
    assert is_integer(Scheduler.monotonic_time(RecordingScheduler, :millisecond))
    assert_receive {:scheduler_monotonic_time, :millisecond, _}
    cancel_result = Scheduler.cancel_timer(RecordingScheduler, timer_ref)
    assert cancel_result == false or is_integer(cancel_result)
    assert_receive {:scheduler_cancel_timer, ^timer_ref}
  end

  test "memory and skill seams raise clear errors when an adapter fails" do
    failing_issue = %Issue{id: "issue-fail", identifier: "ARC-62", title: "Failure"}

    failing_memory = fn ->
      MemoryBackend.prompt_context(failing_issue, "/tmp", memory_backend: __MODULE__.FailingMemoryBackend)
    end

    failing_skill = fn ->
      SkillRuntime.prompt_context(failing_issue, "/tmp", skill_runtime: __MODULE__.FailingSkillRuntime)
    end

    assert_raise RuntimeError, ~r/memory_backend_error/, failing_memory
    assert_raise RuntimeError, ~r/skill_runtime_error/, failing_skill
  end

  defmodule FailingMemoryBackend do
    @behaviour SymphonyElixir.MemoryBackend

    def prompt_context(_issue, _workspace, _opts), do: {:error, :memory_unavailable}
  end

  defmodule FailingSkillRuntime do
    @behaviour SymphonyElixir.SkillRuntime

    def prompt_context(_issue, _workspace, _opts), do: {:error, :skill_runtime_unavailable}
  end
end
