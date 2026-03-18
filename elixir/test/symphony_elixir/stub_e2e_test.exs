defmodule SymphonyElixir.StubE2eTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Tracker.Stub
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.{HttpServer, Orchestrator}

  test "stub tracker intake routes through orchestrator dispatch and terminal retry cleanup" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-stub-e2e-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(workspace_root)

      File.write!(codex_binary, """
      #!/bin/sh

      while IFS= read -r line; do
        if echo "$line" | grep -q '"id":1'; then
          printf '%s\\n' '{\"id\":1,\"result\":{}}'
          continue
        fi

        if echo "$line" | grep -q '"method":"initialized"'; then
          continue
        fi

        if echo "$line" | grep -q '"id":2'; then
          printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-stub\"}}}'
          continue
        fi

        if echo "$line" | grep -q '"id":3' || echo "$line" | grep -q '"method":"turn/start"'; then
          printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-stub\"}}}'
          printf '%s\\n' '{\"method\":\"turn/completed\"}'
          continue
        fi
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "stub",
        tracker_project_slug: "execution",
        workspace_root: workspace_root,
        hook_after_create: "printf 'created\\n' > README.md",
        codex_command: "#{codex_binary} app-server"
      )

      :ok = Stub.clear_for_test()
      Application.put_env(:symphony_elixir, :stub_tracker_recipient, self())

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :stub_tracker_recipient)
      end)

      orchestrator_name = Module.concat(__MODULE__, :StubE2eOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      port =
        start_test_http_server(
          host: "127.0.0.1",
          port: 0,
          orchestrator: orchestrator_name,
          snapshot_timeout_ms: 500
        )

      assert %{
               "status" => "accepted",
               "issue_id" => "stub-issue-todo",
               "issue_identifier" => "ST-1000"
             } =
               post_stub_intake!(port, %{
                 "issue" => %{
                   "id" => "stub-issue-todo",
                   "identifier" => "ST-1000",
                   "title" => "Mapped execution ticket",
                   "state" => %{"name" => "Todo"},
                   "projectSlug" => "execution"
                 }
               })

      assert %{
               "status" => "accepted",
               "issue_id" => "stub-issue-ignored",
               "issue_identifier" => "ST-2000"
             } =
               post_stub_intake!(port, %{
                 "issue" => %{
                   "id" => "stub-issue-ignored",
                   "identifier" => "ST-2000",
                   "title" => "Other project ticket",
                   "state" => %{"name" => "Todo"},
                   "projectSlug" => "other"
                 }
               })

      assert :error = query_issue_payload(port, "MT-999")

      assert %Issue{
               id: "stub-issue-todo",
               identifier: "ST-1000",
               title: "Mapped execution ticket",
               state: "Todo",
               project_slug: "execution"
             } = Stub.issue_for_test("stub-issue-todo")

      assert Stub.issue_for_test("stub-issue-ignored") == nil

      send(pid, :run_poll_cycle)

      assert wait_for_state(pid, fn state ->
               Map.has_key?(state.running, "stub-issue-todo") and
                 !Map.has_key?(state.running, "stub-issue-ignored")
             end)

      assert wait_for_file_created(Path.join(workspace_root, "ST-1000"), 120, 10) == :ok
      refute File.exists?(Path.join(workspace_root, "ST-2000"))

      assert wait_for_state(pid, fn state ->
               state.running["stub-issue-todo"] == nil and
                 MapSet.member?(state.completed, "stub-issue-todo") and
                 state.retry_attempts["stub-issue-todo"] != nil
             end)

      assert Stub.issue_for_test("stub-issue-todo").state == "Todo"

      assert :ok = Stub.set_issue_state_for_test("stub-issue-todo", "Done")
      assert_receive {:stub_tracker_state_update, "stub-issue-todo", "Done"}
      state_after_completion = :sys.get_state(pid)
      assert %{} = retry_state = state_after_completion.retry_attempts["stub-issue-todo"]
      assert is_reference(retry_state.retry_token)
      retry_token = retry_state.retry_token

      send(pid, {:retry_issue, "stub-issue-todo", retry_token})

      assert wait_for_state(
               pid,
               fn state ->
                 state.running["stub-issue-todo"] == nil and
                   !MapSet.member?(state.claimed, "stub-issue-todo") and
                   state.retry_attempts["stub-issue-todo"] == nil
               end,
               120,
               10
             )

      assert wait_for_issue_absence(port, "ST-1000", 120, 10) == :ok
      assert wait_for_issue_absence(port, "ST-2000", 120, 10) == :ok
      assert wait_for_file_cleanup(Path.join(workspace_root, "ST-1000"), 200, 10)
      assert Stub.issue_for_test("stub-issue-todo").state == "Done"
    after
      File.rm_rf(test_root)
    end
  end

  defp wait_for_state(pid, predicate, attempts \\ 120, delay_ms \\ 25)

  defp wait_for_state(pid, predicate, attempts, delay_ms)
       when is_integer(attempts) and attempts > 0 do
    state = :sys.get_state(pid)

    if predicate.(state) do
      true
    else
      Process.sleep(delay_ms)
      wait_for_state(pid, predicate, attempts - 1, delay_ms)
    end
  end

  defp wait_for_state(pid, predicate, attempts, _delay_ms) when attempts <= 0 do
    state = :sys.get_state(pid)

    flunk("timed out waiting for orchestrator state to match predicate: #{inspect(predicate)} in #{inspect(state)}")
  end

  defp wait_for_file_cleanup(path, attempts, delay_ms)
       when is_integer(attempts) and attempts > 0 do
    if File.exists?(path) do
      Process.sleep(delay_ms)
      wait_for_file_cleanup(path, attempts - 1, delay_ms)
    else
      :ok
    end
  end

  defp wait_for_file_cleanup(path, attempts, _delay_ms) when attempts <= 0 do
    flunk("timed out waiting for workspace cleanup at #{path}")
  end

  defp wait_for_file_created(path, attempts, delay_ms)
       when is_integer(attempts) and attempts > 0 do
    if File.exists?(path) do
      :ok
    else
      Process.sleep(delay_ms)
      wait_for_file_created(path, attempts - 1, delay_ms)
    end
  end

  defp wait_for_file_created(path, attempts, _delay_ms) when attempts <= 0 do
    flunk("timed out waiting for workspace setup at #{path}")
  end

  defp wait_for_issue_absence(port, issue_identifier, attempts, delay_ms)
       when is_binary(issue_identifier) do
    case query_issue_payload(port, issue_identifier) do
      :error ->
        :ok

      {:ok, _payload} ->
        Process.sleep(delay_ms)
        wait_for_issue_absence(port, issue_identifier, attempts - 1, delay_ms)
    end
  end

  defp wait_for_issue_absence(_port, _issue_identifier, attempts, _delay_ms) when attempts <= 0 do
    flunk("timed out waiting for issue payload removal")
  end

  defp query_issue_payload(port, issue_identifier) when is_binary(issue_identifier) do
    response = Req.get!("http://127.0.0.1:#{port}/api/v1/#{issue_identifier}")

    case response.status do
      200 ->
        {:ok, response.body}

      404 ->
        :error

      status ->
        flunk("unexpected issue endpoint status=#{status}")
    end
  end

  defp post_stub_intake!(port, payload) when is_integer(port) and is_map(payload) do
    response = Req.post!("http://127.0.0.1:#{port}/api/v1/stub/intake", json: payload)

    assert response.status == 202
    response.body
  end

  defp start_test_http_server(overrides) do
    start_supervised!({HttpServer, overrides})
    wait_for_bound_port()
  end

  defp wait_for_bound_port(attempts \\ 100)

  defp wait_for_bound_port(attempts) when attempts > 0 do
    case HttpServer.bound_port() do
      port when is_integer(port) ->
        port

      _ ->
        Process.sleep(10)
        wait_for_bound_port(attempts - 1)
    end
  end

  defp wait_for_bound_port(_attempts) do
    flunk("timed out waiting for test http server port")
  end
end
