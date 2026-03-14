defmodule SymphonyElixir.Acp.Client do
  @moduledoc """
  Minimal ACP client for stdio-based agent backends.
  """

  require Logger

  alias SymphonyElixir.{Config, PathSafety, SSH, StageRouting}

  @initialize_id 1
  @session_new_id 2
  @port_line_bytes 1_048_576
  @protocol_version 1
  @max_stream_log_bytes 1_000

  @type session :: %{
          backend: String.t(),
          bypass_permissions: boolean(),
          metadata: map(),
          port: port(),
          read_timeout_ms: pos_integer(),
          session_id: String.t(),
          stall_timeout_ms: non_neg_integer(),
          turn_timeout_ms: pos_integer(),
          worker_host: String.t() | nil,
          workspace: Path.t()
        }

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    backend = normalize_backend_name(Keyword.get(opts, :backend))
    stage = Keyword.get(opts, :stage)

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         {:ok, backend_config} <- runtime_config(backend, stage),
         {:ok, port} <- start_port(expanded_workspace, worker_host, backend_config),
         metadata = port_metadata(port, worker_host),
         {:ok, _initialize_result} <- send_initialize(port, backend_config.read_timeout_ms),
         {:ok, session_result} <- start_remote_session(port, expanded_workspace, backend_config.read_timeout_ms) do
      case session_id_from_result(session_result) do
        {:ok, session_id} ->
          with :ok <-
                 maybe_set_session_mode(
                   port,
                   session_id,
                   backend_config.mode,
                   session_result,
                   backend_config.read_timeout_ms
                 ),
               :ok <-
                 maybe_set_session_model(
                   port,
                   session_id,
                   backend_config.model,
                   session_result,
                   backend_config.read_timeout_ms
                 ) do
            {:ok,
             %{
               backend: backend,
               bypass_permissions: backend_config.bypass_permissions,
               metadata: metadata,
               port: port,
               read_timeout_ms: backend_config.read_timeout_ms,
               session_id: session_id,
               stall_timeout_ms: backend_config.stall_timeout_ms,
               turn_timeout_ms: backend_config.turn_timeout_ms,
               worker_host: worker_host,
               workspace: expanded_workspace
             }}
          else
            {:error, reason} ->
              stop_port(port)
              {:error, reason}
          end

        {:error, reason} ->
          stop_port(port)
          {:error, reason}
      end
    else
      {:error, reason} ->
        {:error, normalize_start_error(backend, reason)}
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          backend: backend,
          bypass_permissions: bypass_permissions,
          metadata: metadata,
          port: port,
          session_id: session_id
        } = session,
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    turn_id = generate_turn_id()
    combined_id = "#{session_id}-#{turn_id}"
    prompt_request_id = generate_request_id()

    emit_message(
      on_message,
      :session_started,
      %{
        backend: backend,
        session_id: combined_id,
        thread_id: session_id,
        turn_id: turn_id
      },
      metadata
    )

    Logger.info("ACP session started for #{issue_context(issue)} session_id=#{combined_id} backend=#{backend}")

    send_message(port, %{
      "jsonrpc" => "2.0",
      "id" => prompt_request_id,
      "method" => "session/prompt",
      "params" => %{
        "sessionId" => session_id,
        "prompt" => [
          %{
            "type" => "text",
            "text" => prompt
          }
        ]
      }
    })

    case await_turn_completion(port, prompt_request_id, on_message, session, bypass_permissions, combined_id) do
      {:ok, stop_reason} ->
        Logger.info("ACP session completed for #{issue_context(issue)} session_id=#{combined_id} backend=#{backend} stop_reason=#{stop_reason}")

        emit_message(
          on_message,
          :turn_completed,
          %{
            backend: backend,
            session_id: combined_id,
            stop_reason: stop_reason
          },
          metadata
        )

        {:ok,
         %{
           backend: backend,
           result: normalize_stop_reason(stop_reason),
           session_id: combined_id,
           stop_reason: stop_reason,
           thread_id: session_id,
           turn_id: turn_id
         }}

      {:error, reason} ->
        Logger.warning("ACP session ended with error for #{issue_context(issue)} session_id=#{combined_id} backend=#{backend}: #{inspect(reason)}")

        emit_message(
          on_message,
          :turn_ended_with_error,
          %{
            backend: backend,
            session_id: combined_id,
            reason: reason
          },
          metadata
        )

        {:error, reason}
    end
  end

  @spec stop_session(session() | map()) :: :ok
  def stop_session(%{port: port}) when is_port(port), do: stop_port(port)
  def stop_session(_session), do: :ok

  defp runtime_config(backend, stage) when is_binary(backend) do
    case Config.acp_backend_config(backend) do
      nil -> {:error, {:unknown_backend, backend}}
      config -> {:ok, maybe_override_stage_model(config, stage)}
    end
  end

  defp normalize_backend_name(backend) when is_binary(backend) do
    StageRouting.normalize_backend(backend) || backend
  end

  defp normalize_backend_name(nil), do: Config.agent_backend()
  defp normalize_backend_name(backend), do: to_string(backend)

  defp maybe_override_stage_model(config, stage) when is_map(config) do
    case Config.stage_model_override(stage) do
      model when is_binary(model) -> Map.put(config, :model, model)
      _ -> config
    end
  end

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host) when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp start_port(workspace, nil, backend_config) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      command = "exec " <> backend_config.command

      port_options =
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: [~c"-lc", String.to_charlist(command)],
          cd: String.to_charlist(workspace),
          line: @port_line_bytes
        ] ++ local_env_port_options(backend_config.env)

      port = Port.open({:spawn_executable, String.to_charlist(executable)}, port_options)
      {:ok, port}
    end
  end

  defp start_port(workspace, worker_host, backend_config) when is_binary(worker_host) do
    SSH.start_port(worker_host, remote_launch_command(workspace, backend_config), line: @port_line_bytes)
  end

  defp local_env_port_options(env) when map_size(env) == 0, do: []

  defp local_env_port_options(env) do
    [
      env:
        Enum.map(env, fn {key, value} ->
          {String.to_charlist(key), String.to_charlist(value)}
        end)
    ]
  end

  defp remote_launch_command(workspace, %{command: command, env: env}) do
    env_exports =
      env
      |> Enum.map(fn {key, value} -> "export #{key}=#{shell_escape(value)}" end)
      |> Enum.join(" && ")

    [env_exports, "cd #{shell_escape(workspace)}", "exec #{command}"]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" && ")
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{
            acp_server_pid: to_string(os_pid),
            codex_app_server_pid: to_string(os_pid)
          }

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp send_initialize(port, timeout_ms) do
    send_message(port, %{
      "jsonrpc" => "2.0",
      "id" => @initialize_id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @protocol_version,
        "clientCapabilities" => %{}
      }
    })

    case await_response(port, @initialize_id, timeout_ms) do
      {:ok, %{"protocolVersion" => @protocol_version} = result} -> {:ok, result}
      {:ok, %{"protocolVersion" => protocol_version}} -> {:error, {:unsupported_protocol_version, protocol_version}}
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_remote_session(port, workspace, timeout_ms) do
    send_message(port, %{
      "jsonrpc" => "2.0",
      "id" => @session_new_id,
      "method" => "session/new",
      "params" => %{
        "cwd" => workspace,
        "mcpServers" => []
      }
    })

    await_response(port, @session_new_id, timeout_ms)
  end

  defp session_id_from_result(%{"sessionId" => session_id}) when is_binary(session_id), do: {:ok, session_id}
  defp session_id_from_result(result), do: {:error, {:invalid_session_payload, result}}

  defp maybe_set_session_mode(_port, _session_id, nil, _session_result, _timeout_ms), do: :ok

  defp maybe_set_session_mode(port, session_id, mode_id, session_result, timeout_ms) when is_binary(mode_id) do
    available_modes =
      session_result
      |> Map.get("modes", %{})
      |> Map.get("availableModes", [])

    if mode_available?(available_modes, mode_id) do
      request_id = generate_request_id()

      send_message(port, %{
        "jsonrpc" => "2.0",
        "id" => request_id,
        "method" => "session/set_mode",
        "params" => %{
          "sessionId" => session_id,
          "modeId" => mode_id
        }
      })

      case await_response(port, request_id, timeout_ms) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, {:unsupported_session_mode, mode_id}}
    end
  end

  defp maybe_set_session_model(_port, _session_id, nil, _session_result, _timeout_ms), do: :ok

  defp maybe_set_session_model(port, session_id, model_preference, session_result, timeout_ms)
       when is_binary(model_preference) do
    available_models =
      session_result
      |> Map.get("configOptions", [])
      |> config_option_values("model")

    case resolve_config_option_value(available_models, model_preference) do
      nil ->
        {:error, {:unsupported_session_model, model_preference}}

      model_id ->
        request_id = generate_request_id()

        send_message(port, %{
          "jsonrpc" => "2.0",
          "id" => request_id,
          "method" => "session/set_config_option",
          "params" => %{
            "sessionId" => session_id,
            "configId" => "model",
            "value" => model_id
          }
        })

        case await_response(port, request_id, timeout_ms) do
          {:ok, _result} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp await_response(port, response_id, timeout_ms, pending_line \\ "", raw_lines \\ []) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)

        case Jason.decode(complete_line) do
          {:ok, %{"id" => ^response_id, "result" => result}} ->
            {:ok, result}

          {:ok, %{"id" => ^response_id, "error" => error}} ->
            {:error, normalize_rpc_error(error)}

          {:ok, _other_payload} ->
            await_response(port, response_id, timeout_ms, "", [complete_line | raw_lines])

          {:error, _reason} ->
            await_response(port, response_id, timeout_ms, "", [complete_line | raw_lines])
        end

      {^port, {:data, {:noeol, chunk}}} ->
        await_response(port, response_id, timeout_ms, pending_line <> to_string(chunk), raw_lines)

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status, finalize_output(raw_lines, pending_line)}}
    after
      timeout_ms ->
        {:error, :read_timeout}
    end
  end

  defp await_turn_completion(
         port,
         prompt_request_id,
         on_message,
         %{
           metadata: metadata,
           session_id: session_id,
           stall_timeout_ms: stall_timeout_ms,
           turn_timeout_ms: turn_timeout_ms
         } = session,
         bypass_permissions,
         combined_id
       ) do
    deadline_ms = System.monotonic_time(:millisecond) + turn_timeout_ms
    stall_deadline_ms = next_stall_deadline(stall_timeout_ms)

    receive_turn_loop(
      port,
      prompt_request_id,
      on_message,
      session,
      bypass_permissions,
      combined_id,
      metadata,
      session_id,
      deadline_ms,
      stall_deadline_ms,
      ""
    )
  end

  defp receive_turn_loop(
         port,
         prompt_request_id,
         on_message,
         session,
         bypass_permissions,
         combined_id,
         metadata,
         session_id,
         deadline_ms,
         stall_deadline_ms,
         pending_line
       ) do
    timeout_ms = receive_timeout(deadline_ms, stall_deadline_ms)

    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)

        handle_turn_payload(
          port,
          prompt_request_id,
          complete_line,
          on_message,
          session,
          bypass_permissions,
          combined_id,
          metadata,
          session_id,
          deadline_ms,
          next_stall_deadline(session.stall_timeout_ms)
        )

      {^port, {:data, {:noeol, chunk}}} ->
        receive_turn_loop(
          port,
          prompt_request_id,
          on_message,
          session,
          bypass_permissions,
          combined_id,
          metadata,
          session_id,
          deadline_ms,
          stall_deadline_ms,
          pending_line <> to_string(chunk)
        )

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        cond do
          deadline_expired?(deadline_ms) ->
            {:error, :turn_timeout}

          stall_expired?(stall_deadline_ms) ->
            {:error, :stall_timeout}

          true ->
            {:error, :turn_timeout}
        end
    end
  end

  defp handle_turn_payload(
         port,
         prompt_request_id,
         payload_string,
         on_message,
         session,
         bypass_permissions,
         combined_id,
         metadata,
         session_id,
         deadline_ms,
         stall_deadline_ms
       ) do
    case Jason.decode(payload_string) do
      {:ok, %{"id" => ^prompt_request_id, "result" => %{"stopReason" => stop_reason}}} ->
        {:ok, stop_reason}

      {:ok, %{"id" => ^prompt_request_id, "error" => error}} ->
        {:error, normalize_rpc_error(error)}

      {:ok, %{"method" => "session/update", "params" => params} = payload} ->
        emit_message(
          on_message,
          :notification,
          %{
            backend: session.backend,
            session_id: combined_id,
            payload: payload,
            raw: payload_string,
            details: params
          },
          metadata
        )

        receive_turn_loop(
          port,
          prompt_request_id,
          on_message,
          session,
          bypass_permissions,
          combined_id,
          metadata,
          session_id,
          deadline_ms,
          stall_deadline_ms,
          ""
        )

      {:ok, %{"method" => "session/request_permission", "id" => permission_id, "params" => params} = payload} ->
        emit_message(
          on_message,
          :notification,
          %{
            backend: session.backend,
            session_id: combined_id,
            payload: payload,
            raw: payload_string,
            details: params
          },
          metadata
        )

        send_message(port, %{
          "jsonrpc" => "2.0",
          "id" => permission_id,
          "result" => %{
            "outcome" => permission_outcome(params, bypass_permissions)
          }
        })

        receive_turn_loop(
          port,
          prompt_request_id,
          on_message,
          session,
          bypass_permissions,
          combined_id,
          metadata,
          session_id,
          deadline_ms,
          stall_deadline_ms,
          ""
        )

      {:ok, %{"method" => method} = payload} when is_binary(method) ->
        emit_message(
          on_message,
          :notification,
          %{
            backend: session.backend,
            session_id: combined_id,
            payload: payload,
            raw: payload_string,
            details: Map.get(payload, "params")
          },
          metadata
        )

        receive_turn_loop(
          port,
          prompt_request_id,
          on_message,
          session,
          bypass_permissions,
          combined_id,
          metadata,
          session_id,
          deadline_ms,
          stall_deadline_ms,
          ""
        )

      {:ok, payload} ->
        emit_message(
          on_message,
          :other_message,
          %{
            backend: session.backend,
            session_id: combined_id,
            payload: payload,
            raw: payload_string
          },
          metadata
        )

        receive_turn_loop(
          port,
          prompt_request_id,
          on_message,
          session,
          bypass_permissions,
          combined_id,
          metadata,
          session_id,
          deadline_ms,
          stall_deadline_ms,
          ""
        )

      {:error, _reason} ->
        log_non_json_stream_line(payload_string, "acp stream")

        emit_message(
          on_message,
          :malformed,
          %{
            backend: session.backend,
            session_id: combined_id,
            payload: payload_string,
            raw: payload_string
          },
          metadata
        )

        receive_turn_loop(
          port,
          prompt_request_id,
          on_message,
          session,
          bypass_permissions,
          combined_id,
          metadata,
          session_id,
          deadline_ms,
          stall_deadline_ms,
          ""
        )
    end
  end

  defp permission_outcome(params, bypass_permissions) do
    options = Map.get(params, "options", [])

    selected_option =
      if bypass_permissions do
        select_permission_option(options, ["allow_always", "allow_once", "allow"])
      else
        select_permission_option(options, ["allow_once", "allow_always", "allow"])
      end ||
        select_permission_option(options, ["reject_once", "reject_always", "reject"])

    case selected_option do
      %{"optionId" => option_id} ->
        %{
          "outcome" => "selected",
          "optionId" => option_id
        }

      _ ->
        %{"outcome" => "cancelled"}
    end
  end

  defp select_permission_option(options, preferred_kinds) when is_list(options) do
    Enum.find(options, fn option ->
      option_value = Map.get(option, "optionId") || Map.get(option, "kind")
      option_value in preferred_kinds and is_binary(Map.get(option, "optionId"))
    end)
  end

  defp mode_available?(available_modes, mode_id) when is_list(available_modes) do
    Enum.any?(available_modes, fn mode ->
      Map.get(mode, "id") == mode_id
    end)
  end

  defp config_option_values(config_options, option_id) when is_list(config_options) and is_binary(option_id) do
    config_options
    |> Enum.find_value([], fn option ->
      if Map.get(option, "id") == option_id do
        Map.get(option, "options", [])
      end
    end)
  end

  defp resolve_config_option_value(options, preference) when is_list(options) and is_binary(preference) do
    normalized_preference = String.downcase(String.trim(preference))

    Enum.find_value(options, fn option ->
      value = Map.get(option, "value")
      name = Map.get(option, "name", "")

      cond do
        value == preference ->
          value

        is_binary(value) and String.downcase(value) == normalized_preference ->
          value

        is_binary(name) and String.downcase(name) == normalized_preference ->
          value

        is_binary(value) and String.contains?(String.downcase(value), normalized_preference) ->
          value

        is_binary(name) and String.contains?(String.downcase(name), normalized_preference) ->
          value

        true ->
          nil
      end
    end)
  end

  defp receive_timeout(deadline_ms, stall_deadline_ms) do
    [
      milliseconds_until(deadline_ms),
      milliseconds_until(stall_deadline_ms)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> 0
      values -> Enum.min(values)
    end
  end

  defp milliseconds_until(:infinity), do: nil

  defp milliseconds_until(target_ms) when is_integer(target_ms) do
    max(target_ms - System.monotonic_time(:millisecond), 0)
  end

  defp next_stall_deadline(0), do: :infinity
  defp next_stall_deadline(stall_timeout_ms), do: System.monotonic_time(:millisecond) + stall_timeout_ms

  defp deadline_expired?(deadline_ms) do
    System.monotonic_time(:millisecond) >= deadline_ms
  end

  defp stall_expired?(:infinity), do: false
  defp stall_expired?(stall_deadline_ms), do: System.monotonic_time(:millisecond) >= stall_deadline_ms

  defp generate_turn_id do
    "turn-" <> Base.url_encode64(:crypto.strong_rand_bytes(4), padding: false)
  end

  defp generate_request_id do
    :erlang.unique_integer([:positive, :monotonic])
  end

  defp normalize_stop_reason("end_turn"), do: :turn_completed
  defp normalize_stop_reason(stop_reason), do: stop_reason

  defp normalize_start_error(backend, :bash_not_found), do: {:backend_unavailable, backend, :bash_not_found}

  defp normalize_start_error(backend, {:port_exit, 127, raw_output}),
    do: {:backend_unavailable, backend, {:port_exit, 127, raw_output}}

  defp normalize_start_error(_backend, reason), do: reason

  defp normalize_rpc_error(%{"code" => code, "message" => message} = error) do
    data = Map.get(error, "data")

    case data do
      %{"type" => "auth_required"} ->
        {:auth_required, data}

      _ ->
        {:rpc_error, code, message, data}
    end
  end

  defp send_message(port, payload) when is_port(port) do
    Port.command(port, Jason.encode!(payload) <> "\n")
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        os_pid = port_os_pid(port)

        try do
          Port.close(port)
        rescue
          ArgumentError -> :ok
        end

        terminate_os_process(os_pid)
        :ok
    end
  end

  defp port_os_pid(port) when is_port(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) -> os_pid
      _ -> nil
    end
  end

  defp terminate_os_process(nil), do: :ok

  defp terminate_os_process(os_pid) when is_integer(os_pid) do
    pid = Integer.to_string(os_pid)

    signal_os_process("-TERM", pid)

    if os_process_alive?(pid) do
      Process.sleep(100)

      if os_process_alive?(pid) do
        signal_os_process("-KILL", pid)
      end
    end

    :ok
  end

  defp signal_os_process(signal, pid) when is_binary(signal) and is_binary(pid) do
    case System.cmd(kill_executable(), [signal, pid], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      _ -> :ok
    end
  end

  defp os_process_alive?(pid) when is_binary(pid) do
    case System.cmd(kill_executable(), ["-0", pid], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  end

  defp kill_executable do
    System.find_executable("kill") || "/bin/kill"
  end

  defp finalize_output(raw_lines, pending_line) do
    lines = if pending_line != "", do: [pending_line | raw_lines], else: raw_lines
    lines |> Enum.reverse() |> Enum.join("\n")
  end

  defp log_non_json_stream_line(line, label) when is_binary(line) do
    trimmed = String.trim(line)

    if trimmed != "" do
      Logger.debug("#{label} non-json output=#{inspect(String.slice(trimmed, 0, @max_stream_log_bytes))}")
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp issue_context(_issue), do: "issue_id=unknown"

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message =
      details
      |> Map.merge(%{event: event, timestamp: DateTime.utc_now()})
      |> Map.merge(metadata)

    on_message.(message)
  end

  defp default_on_message(_message), do: :ok
end
