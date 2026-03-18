defmodule SymphonyElixir.HumanReviewStateTest do
  use SymphonyElixir.TestSupport

  test "config resolves the human review safeguard state from tracker settings" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo", "In Progress", "BLOCKED - requires human"]
    )

    assert Config.settings!().tracker.human_review_state == nil
    assert Config.human_review_state() == "BLOCKED - requires human"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_human_review_state: "Manual Review",
      tracker_active_states: ["Todo", "In Progress", "BLOCKED - requires human"]
    )

    assert Config.settings!().tracker.human_review_state == "Manual Review"
    assert Config.human_review_state() == "Manual Review"
  end

  test "human review safeguard uses the configured tracker state" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress", "BLOCKED - requires human"]
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    assert :ok =
             SymphonyElixir.Orchestrator.CodexTracking.maybe_move_issue_to_human_review(
               "issue-human-state",
               "MT-HUMAN",
               "token budget exceeded",
               "details",
               Config.human_review_state()
             )

    assert_receive {:memory_tracker_state_update, "issue-human-state", "BLOCKED - requires human"}
    assert_receive {:memory_tracker_comment, "issue-human-state", comment}
    assert comment =~ "token budget exceeded"
  end

  test "effective active states exclude the human review state" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_human_review_state: "BLOCKED - requires human",
      tracker_active_states: ["Todo", "In Progress", "BLOCKED - requires human"]
    )

    assert Config.active_states() == ["Todo", "In Progress"]
  end
end
