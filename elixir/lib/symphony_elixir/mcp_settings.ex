defmodule SymphonyElixir.McpSettings do
  @moduledoc false

  @claude_settings_path [".claude", "settings.json"]

  @spec acp_mcp_servers(Path.t() | nil) :: map()
  def acp_mcp_servers(workspace) when is_binary(workspace) do
    workspace
    |> claude_settings_file()
    |> File.read()
    |> case do
      {:ok, contents} ->
        with {:ok, decoded} <- Jason.decode(contents),
             %{} = servers <- normalize_servers(Map.get(decoded, "mcpServers")) do
          servers
        else
          _ -> %{}
        end

      {:error, _reason} ->
        %{}
    end
  end

  def acp_mcp_servers(_workspace), do: %{}

  @spec codex_config_overrides(Path.t() | nil) :: [String.t()]
  def codex_config_overrides(workspace) do
    workspace
    |> acp_mcp_servers()
    |> Enum.sort_by(fn {name, _config} -> name end)
    |> Enum.flat_map(fn {name, config} -> codex_server_overrides(name, config) end)
  end

  @spec loaded_server_names(Path.t() | nil) :: [String.t()]
  def loaded_server_names(workspace) do
    workspace
    |> acp_mcp_servers()
    |> Map.keys()
    |> Enum.sort()
  end

  defp claude_settings_file(workspace) do
    Path.join([workspace | @claude_settings_path])
  end

  defp normalize_servers(servers) when is_map(servers) do
    Enum.reduce(servers, %{}, fn {name, config}, acc ->
      case normalize_server(config) do
        nil -> acc
        normalized -> Map.put(acc, to_string(name), normalized)
      end
    end)
  end

  defp normalize_servers(_servers), do: %{}

  defp normalize_server(%{"type" => "http", "url" => url} = server) when is_binary(url) do
    bearer_token_env_var =
      case Map.get(server, "bearerTokenEnvVar") do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end

    %{"url" => url}
    |> maybe_put("bearerTokenEnvVar", bearer_token_env_var)
  end

  defp normalize_server(%{"url" => url} = server) when is_binary(url) do
    bearer_token_env_var =
      case Map.get(server, "bearerTokenEnvVar") do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end

    %{"url" => url}
    |> maybe_put("bearerTokenEnvVar", bearer_token_env_var)
  end

  defp normalize_server(%{"command" => command} = server) when is_binary(command) do
    args =
      server
      |> Map.get("args", [])
      |> normalize_string_list()

    env =
      server
      |> Map.get("env", %{})
      |> normalize_string_map()

    %{"command" => command}
    |> maybe_put("args", args, args != [])
    |> maybe_put("env", env, map_size(env) > 0)
  end

  defp normalize_server(_server), do: nil

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
  end

  defp normalize_string_list(_values), do: []

  defp normalize_string_map(values) when is_map(values) do
    Enum.reduce(values, %{}, fn {key, value}, acc ->
      if is_binary(value) do
        Map.put(acc, to_string(key), value)
      else
        acc
      end
    end)
  end

  defp normalize_string_map(_values), do: %{}

  defp codex_server_overrides(name, %{"url" => url} = server) do
    [
      config_override("mcp_servers.#{name}.url", toml_string(url))
      | maybe_bearer_override(name, Map.get(server, "bearerTokenEnvVar"))
    ]
  end

  defp codex_server_overrides(name, %{"command" => command} = server) do
    env_overrides =
      server
      |> Map.get("env", %{})
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, value} ->
        config_override("mcp_servers.#{name}.env.#{key}", toml_string(value))
      end)

    [
      config_override("mcp_servers.#{name}.command", toml_string(command))
      | maybe_args_override(name, Map.get(server, "args", []))
    ] ++ env_overrides
  end

  defp maybe_args_override(_name, []), do: []

  defp maybe_args_override(name, args) do
    [config_override("mcp_servers.#{name}.args", toml_array(args))]
  end

  defp maybe_bearer_override(_name, nil), do: []

  defp maybe_bearer_override(name, bearer_token_env_var) do
    [config_override("mcp_servers.#{name}.bearer_token_env_var", toml_string(bearer_token_env_var))]
  end

  defp config_override(key, value) do
    "--config " <> shell_escape("#{key}=#{value}")
  end

  defp toml_array(values) do
    "[" <> Enum.map_join(values, ", ", &toml_string/1) <> "]"
  end

  defp toml_string(value) when is_binary(value) do
    Jason.encode!(value)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put(map, _key, _value, false), do: map
  defp maybe_put(map, key, value, true), do: Map.put(map, key, value)

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
