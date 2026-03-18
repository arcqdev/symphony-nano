defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

  test "tool_specs advertises the sync_workpad input contract" do
    assert [
             %{
               "description" => description,
               "inputSchema" => %{
                 "properties" => %{
                   "comment_id" => _,
                   "file_path" => _,
                   "issue_id" => _
                 },
                 "required" => ["issue_id", "file_path"],
                 "type" => "object"
               },
               "name" => "sync_workpad"
             }
           ] = DynamicTool.tool_specs()

    assert description =~ "workpad"
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["sync_workpad"]
             }
           }

    assert response["contentItems"] == [
             %{
               "type" => "inputText",
               "text" => response["output"]
             }
           ]
  end

  test "unsupported tools remain unsupported even when arguments are present" do
    response =
      DynamicTool.execute("linear_graphql", %{"query" => "query Viewer { viewer { id } }"})

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "linear_graphql".),
               "supportedTools" => ["sync_workpad"]
             }
           }
  end

  test "sync_workpad reads the file from the current workspace and delegates to the tracker seam" do
    workspace_root = tmp_dir!("dynamic-tool-workspace")
    workpad_path = Path.join(workspace_root, "tmp/workpad.md")
    File.mkdir_p!(Path.dirname(workpad_path))
    File.write!(workpad_path, "## Codex Workpad\n\nSynced from file.\n")

    previous_tracker = Application.get_env(:symphony_elixir, :tracker_module)
    Application.put_env(:symphony_elixir, :tracker_module, SymphonyElixir.Tracker.Stub)

    on_exit(fn ->
      if is_nil(previous_tracker) do
        Application.delete_env(:symphony_elixir, :tracker_module)
      else
        Application.put_env(:symphony_elixir, :tracker_module, previous_tracker)
      end

      SymphonyElixir.Tracker.Stub.clear_for_test()
    end)

    response =
      DynamicTool.execute(
        "sync_workpad",
        %{"issue_id" => "stub-issue-1", "file_path" => "tmp/workpad.md"},
        workspace: workspace_root
      )

    assert response["success"] == true

    assert %{
             "ok" => true,
             "workpad" => %{
               "body" => "## Codex Workpad\n\nSynced from file.\n",
               "createdAt" => _,
               "id" => "stub-workpad-stub-issue-1",
               "resolvedAt" => nil,
               "updatedAt" => _
             }
           } = Jason.decode!(response["output"])
  end

  test "sync_workpad rejects files outside the current workspace" do
    outside_path =
      Path.join(System.tmp_dir!(), "outside-workpad-#{System.unique_integer([:positive])}.md")

    File.write!(outside_path, "outside")
    workspace_root = tmp_dir!("dynamic-tool-contained-workspace")

    response =
      DynamicTool.execute(
        "sync_workpad",
        %{"issue_id" => "issue-1", "file_path" => outside_path},
        workspace: workspace_root
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "inside the current workspace"
  end

  test "sync_workpad validates required arguments" do
    response = DynamicTool.execute("sync_workpad", %{"file_path" => "tmp/workpad.md"})

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "issue_id"
  end

  defp tmp_dir!(name) do
    path = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end
end
