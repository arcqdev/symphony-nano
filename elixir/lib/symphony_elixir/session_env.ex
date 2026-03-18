defmodule SymphonyElixir.SessionEnv do
  @moduledoc false

  @spec aliases() :: map()
  def aliases do
    linear_api_key = normalized_env("LINEAR_API_KEY")
    linear_api_token = normalized_env("LINEAR_API_TOKEN")

    %{}
    |> maybe_put("LINEAR_API_KEY", linear_api_key || linear_api_token)
    |> maybe_put("LINEAR_API_TOKEN", linear_api_token || linear_api_key)
  end

  @spec merge(map()) :: map()
  def merge(overrides) when is_map(overrides) do
    Map.merge(aliases(), overrides)
  end

  defp normalized_env(name) do
    case System.get_env(name) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          _trimmed -> value
        end

      _ ->
        nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
