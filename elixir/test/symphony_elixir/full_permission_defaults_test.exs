defmodule SymphonyElixir.FullPermissionDefaultsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Linear.Issue

  test "default codex runtime settings omit sandbox settings entirely" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-full-permission-defaults-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-FULL")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-full-permissions.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-full-permissions.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-full"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-full"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: nil,
        codex_thread_sandbox: nil,
        codex_turn_sandbox_policy: nil
      )

      issue = %Issue{
        id: "issue-full-defaults",
        identifier: "MT-FULL",
        title: "Validate full permission defaults",
        description: "Ensure default startup policy is unrestricted",
        state: "In Progress",
        url: "https://example.org/issues/MT-FULL",
        labels: ["backend"]
      }

      assert Config.settings!().codex.thread_sandbox == nil
      assert Config.codex_turn_sandbox_policy() == nil
      assert {:ok, _result} = AppServer.run(workspace, "Run mix test in apps/core", issue)

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "never" &&
                     get_in(payload, ["params", "sandbox"]) == nil &&
                     Map.has_key?(payload["params"], "sandbox") == false
                 end)
               else
                 false
               end
             end)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "never" &&
                     get_in(payload, ["params", "sandboxPolicy"]) == nil &&
                     Map.has_key?(payload["params"], "sandboxPolicy") == false
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end
end
