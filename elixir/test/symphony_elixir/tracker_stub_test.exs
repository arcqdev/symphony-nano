defmodule SymphonyElixir.TrackerStubTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Tracker.Stub
  alias SymphonyElixir.Config

  test "stub intake validates required fields and normalizes request payloads" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "stub", tracker_project_slug: "execution")
    assert Config.settings!().tracker.kind == "stub"
    assert SymphonyElixir.Tracker.adapter() == Stub
    :ok = Stub.clear_for_test()
    Application.put_env(:symphony_elixir, :stub_tracker_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :stub_tracker_recipient)
    end)

    {:ok, with_identifier} =
      Stub.submit_request(%{
        "identifier" => "ST-1001",
        "title" => "Symphony stub",
        "state" => "Todo",
        "project_slug" => "execution",
        "created_at" => "2026-03-14T10:00:00Z",
        "labels" => ["A", 123],
        "blocked_by" => [%{"state" => "Todo"}, %{"state" => "Done"}, %{"oops" => 1}]
      })

    assert with_identifier.id == "ST-1001"
    assert with_identifier.identifier == "ST-1001"
    assert with_identifier.title == "Symphony stub"
    assert with_identifier.labels == ["A", "123"]
    assert with_identifier.blocked_by == [%{state: "Todo"}, %{state: "Done"}]
    assert %DateTime{} = with_identifier.created_at

    {:error, {:missing_required_field, "title"}} =
      Stub.submit_request(%{
        "id" => "issue-no-title",
        "project_slug" => "execution"
      })

    {:ok, id_fallback} =
      Stub.submit_request(%{
        "identifier" => "ST-1002",
        "title" => "Fallback ID example",
        "state" => "Todo",
        "project_slug" => "execution"
      })

    assert id_fallback.id == "ST-1002"
    assert id_fallback.identifier == "ST-1002"

    {:ok, id_as_identifier} = Stub.submit_request(%{"id" => "ST-1003", "title" => "ID-only example"})
    assert id_as_identifier.id == "ST-1003"
    assert id_as_identifier.identifier == "ST-1003"
  end

  test "stub tracker filters by configured project and tracks issue lifecycle metadata" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "stub", tracker_project_slug: "execution")
    :ok = Stub.clear_for_test()
    Application.put_env(:symphony_elixir, :stub_tracker_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :stub_tracker_recipient)
    end)

    assert {:ok, mismatched} =
             Stub.submit_request(%{
               "id" => "issue-miss",
               "identifier" => "MISS-1",
               "title" => "Unmapped project",
               "project_slug" => "qa"
             })

    assert mismatched.project_slug == "qa"
    assert Stub.issue_for_test("issue-miss") == nil

    assert {:ok, matched} =
             Stub.submit_request(%{
               "id" => "issue-hit",
               "identifier" => "RUN-1",
               "title" => "Mapped project",
               "project_slug" => "execution",
               "state" => "Todo"
             })

    assert Stub.issue_for_test("issue-hit") == matched
    assert {:ok, [^matched]} = Stub.fetch_candidate_issues()
    assert {:ok, [^matched]} = Stub.fetch_issues_by_states(["todo"])
    assert {:ok, [fetched]} = Stub.fetch_issue_states_by_ids(["issue-hit"])
    assert fetched.id == "issue-hit"
    assert fetched.state == "Todo"

    assert :ok = Stub.create_comment("issue-hit", "symphony picked up issue from stub")
    assert_receive {:stub_tracker_comment, "issue-hit", "symphony picked up issue from stub"}
    assert Stub.comments_for_test("issue-hit") == ["symphony picked up issue from stub"]

    assert :ok = Stub.set_issue_state_for_test("issue-hit", "In Progress")

    assert Stub.issue_for_test("issue-hit").state == "In Progress"
    assert :ok = Stub.create_comment("issue-hit", "status moved forward")

    assert Stub.comments_for_test("issue-hit") == [
             "symphony picked up issue from stub",
             "status moved forward"
           ]

    assert {:ok, [post_update]} = Stub.fetch_issue_states_by_ids(["issue-hit"])
    assert post_update.id == "issue-hit"
    assert post_update.state == "In Progress"
    assert {:error, :missing_issue} = Stub.update_issue_state("missing", "Done")

    assert Stub.issue_for_test("issue-miss") == nil
    assert Config.settings!().tracker.project_slug == "execution"
  end
end
