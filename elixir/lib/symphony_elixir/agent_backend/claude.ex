defmodule SymphonyElixir.AgentBackend.Claude do
  @moduledoc """
  Agent backend adapter for Claude Code (subprocess per turn via `claude -p`).
  """

  @behaviour SymphonyElixir.AgentBackend

  require Logger
  alias SymphonyElixir.{Config, PathSafety}

  @port_line_bytes 1_048_576

  @impl true
  def start_session(workspace, opts) do
    worker_host = Keyword.get(opts, :worker_host)

    with {:ok, expanded_workspace} <- validate_workspace(workspace, worker_host) do
      session_id = generate_session_id()

      {:ok,
       %{
         workspace: expanded_workspace,
         worker_host: worker_host,
         session_id: session_id,
         port: nil
       }}
    end
  end

  @impl true
  def run_turn(session, prompt, issue, opts) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    turn_id = generate_turn_id()
    combined_id = "#{session.session_id}-#{turn_id}"

    emit_message(on_message, :session_started, %{
      session_id: combined_id,
      thread_id: session.session_id,
      turn_id: turn_id
    })

    Logger.info("Claude session started for #{issue_context(issue)} session_id=#{combined_id}")

    case execute_claude(session, prompt, issue) do
      {:ok, output} ->
        Logger.info("Claude session completed for #{issue_context(issue)} session_id=#{combined_id}")

        emit_message(on_message, :turn_completed, %{
          session_id: combined_id,
          output: output
        })

        {:ok,
         %{
           result: :turn_completed,
           session_id: combined_id,
           thread_id: session.session_id,
           turn_id: turn_id,
           output: output
         }}

      {:error, reason} ->
        reason = normalize_run_error(reason)

        Logger.warning("Claude session ended with error for #{issue_context(issue)} session_id=#{combined_id}: #{inspect(reason)}")

        emit_message(on_message, :turn_ended_with_error, %{
          session_id: combined_id,
          reason: reason
        })

        {:error, reason}
    end
  end

  @impl true
  def stop_session(%{port: port}) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError -> :ok
        end
    end
  end

  def stop_session(_session), do: :ok

  defp execute_claude(session, prompt, issue) do
    claude_config = Config.settings!().claude
    command = build_command(claude_config, session, prompt, issue)

    case start_claude_port(command, session.workspace, session.worker_host) do
      {:ok, port} ->
        timeout = claude_config.turn_timeout_ms
        result = collect_output(port, timeout, [])
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_command(claude_config, session, prompt, issue) do
    base = claude_config.command

    args =
      [
        "--output-format",
        "json",
        "--verbose"
      ]
      |> maybe_add_model(claude_config)
      |> maybe_add_max_turns(claude_config)
      |> maybe_add_allowed_tools(claude_config)
      |> maybe_add_session_id(session)
      |> maybe_add_permissions(claude_config)

    prompt_text = format_prompt(prompt, issue)

    Enum.join([base | args] ++ ["-p", shell_escape(prompt_text)], " ")
  end

  defp maybe_add_model(args, %{model: model}) when is_binary(model) and model != "" do
    args ++ ["--model", model]
  end

  defp maybe_add_model(args, _config), do: args

  defp maybe_add_max_turns(args, %{max_turns: max_turns})
       when is_integer(max_turns) and max_turns > 0 do
    args ++ ["--max-turns", to_string(max_turns)]
  end

  defp maybe_add_max_turns(args, _config), do: args

  defp maybe_add_allowed_tools(args, %{allowed_tools: tools})
       when is_list(tools) and tools != [] do
    args ++ Enum.flat_map(tools, fn tool -> ["--allowedTools", tool] end)
  end

  defp maybe_add_allowed_tools(args, _config), do: args

  defp maybe_add_session_id(args, %{session_id: session_id}) when is_binary(session_id) do
    args ++ ["--session-id", session_id]
  end

  defp maybe_add_session_id(args, _session), do: args

  defp maybe_add_permissions(args, %{permissions_mode: mode})
       when is_binary(mode) and mode != "" do
    case mode do
      "skip" -> args ++ ["--dangerously-skip-permissions"]
      _ -> args
    end
  end

  defp maybe_add_permissions(args, _config), do: args

  defp format_prompt(prompt, _issue), do: prompt

  defp start_claude_port(command, workspace, nil) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(command)],
            cd: String.to_charlist(workspace),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp start_claude_port(command, workspace, worker_host) when is_binary(worker_host) do
    remote_command = "cd #{shell_escape(workspace)} && exec #{command}"
    SymphonyElixir.SSH.start_port(worker_host, remote_command, line: @port_line_bytes)
  end

  defp collect_output(port, timeout, acc, pending \\ "") do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending <> to_string(chunk)
        collect_output(port, timeout, [complete_line | acc], "")

      {^port, {:data, {:noeol, chunk}}} ->
        collect_output(port, timeout, acc, pending <> to_string(chunk))

      {^port, {:exit_status, 0}} ->
        raw_output = finalize_output(acc, pending)
        parse_claude_output(raw_output)

      {^port, {:exit_status, status}} ->
        raw_output = finalize_output(acc, pending)
        Logger.warning("Claude exited with status #{status}: #{String.slice(raw_output, 0, 1000)}")
        {:error, {:claude_exit, status, raw_output}}
    after
      timeout ->
        stop_session(%{port: port})
        {:error, :turn_timeout}
    end
  end

  defp finalize_output(acc, pending) do
    lines = if pending != "", do: [pending | acc], else: acc
    lines |> Enum.reverse() |> Enum.join("\n")
  end

  defp parse_claude_output(raw_output) do
    lines = String.split(raw_output, "\n")

    json_line =
      lines
      |> Enum.reverse()
      |> Enum.find(fn line ->
        trimmed = String.trim(line)
        String.starts_with?(trimmed, "{") or String.starts_with?(trimmed, "[")
      end)

    case json_line do
      nil ->
        {:ok, %{"text" => raw_output}}

      line ->
        case Jason.decode(String.trim(line)) do
          {:ok, parsed} -> {:ok, parsed}
          {:error, _} -> {:ok, %{"text" => raw_output}}
        end
    end
  end

  defp validate_workspace(workspace, nil) when is_binary(workspace) do
    expanded = Path.expand(workspace)
    root = Path.expand(Config.settings!().workspace.root)

    with {:ok, canonical} <- PathSafety.canonicalize(expanded),
         {:ok, canonical_root} <- PathSafety.canonicalize(root) do
      cond do
        canonical == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical}}

        String.starts_with?(canonical <> "/", canonical_root <> "/") ->
          {:ok, canonical}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical, canonical_root}}
      end
    end
  end

  defp validate_workspace(workspace, _worker_host) when is_binary(workspace) do
    if String.trim(workspace) == "" or String.contains?(workspace, ["\n", "\r", <<0>>]) do
      {:error, {:invalid_workspace_cwd, :invalid_remote_workspace}}
    else
      {:ok, workspace}
    end
  end

  defp generate_session_id do
    # --session-id requires a valid UUID
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end

  defp generate_turn_id, do: "turn-#{:crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)}"

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp issue_context(_issue), do: "issue_id=unknown"

  defp emit_message(on_message, event, details) when is_function(on_message, 1) do
    message = Map.merge(details, %{event: event, timestamp: DateTime.utc_now()})
    on_message.(message)
  end

  defp default_on_message(_message), do: :ok

  defp normalize_run_error(:bash_not_found), do: {:backend_unavailable, "claude-code", :bash_not_found}

  defp normalize_run_error({:claude_exit, 127, raw_output}),
    do: {:backend_unavailable, "claude-code", {:claude_exit, 127, raw_output}}

  defp normalize_run_error(reason), do: reason
end
