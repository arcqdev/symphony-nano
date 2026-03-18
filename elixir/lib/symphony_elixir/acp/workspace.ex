defmodule SymphonyElixir.Acp.Workspace do
  @moduledoc false

  alias SymphonyElixir.{Config, PathSafety, SessionEnv, SSH}

  @spec validate_workspace_cwd(Path.t(), String.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
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

  def validate_workspace_cwd(workspace, worker_host) when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  @spec start_port(Path.t(), String.t() | nil, map(), pos_integer()) :: {:ok, port()} | {:error, term()}
  def start_port(workspace, nil, backend_config, line_bytes)
      when is_binary(workspace) and is_map(backend_config) and is_integer(line_bytes) and line_bytes > 0 do
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
          line: line_bytes
        ] ++ local_env_port_options(SessionEnv.merge(backend_config.env))

      port = Port.open({:spawn_executable, String.to_charlist(executable)}, port_options)
      {:ok, port}
    end
  end

  def start_port(workspace, worker_host, backend_config, line_bytes)
      when is_binary(workspace) and is_binary(worker_host) and is_map(backend_config) and
             is_integer(line_bytes) and line_bytes > 0 do
    SSH.start_port(worker_host, remote_launch_command(workspace, backend_config), line: line_bytes)
  end

  @spec port_metadata(port(), String.t() | nil) :: map()
  def port_metadata(port, worker_host) when is_port(port) do
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
      |> SessionEnv.merge()
      |> Enum.map(fn {key, value} -> "export #{key}=#{shell_escape(value)}" end)
      |> Enum.join(" && ")

    [env_exports, "cd #{shell_escape(workspace)}", "exec #{command}"]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" && ")
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
