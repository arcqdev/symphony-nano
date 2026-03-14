defmodule SymphonyElixir.Config.Schema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.StageRouting

  @primary_key false

  @type t :: %__MODULE__{}

  @default_acp_backends %{
    "claude-code" => %{
      "command" => "claude-agent-acp",
      "env" => %{}
    }
  }

  @builtin_backend_names ["codex"]

  defmodule StringOrMap do
    @moduledoc false
    @behaviour Ecto.Type

    @spec type() :: :map
    def type, do: :map

    @spec embed_as(term()) :: :self
    def embed_as(_format), do: :self

    @spec equal?(term(), term()) :: boolean()
    def equal?(left, right), do: left == right

    @spec cast(term()) :: {:ok, String.t() | map()} | :error
    def cast(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def cast(_value), do: :error

    @spec load(term()) :: {:ok, String.t() | map()} | :error
    def load(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def load(_value), do: :error

    @spec dump(term()) :: {:ok, String.t() | map()} | :error
    def dump(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def dump(_value), do: :error
  end

  defmodule Tracker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      field(:kind, :string)
      field(:endpoint, :string, default: "https://api.linear.app/graphql")
      field(:api_key, :string)
      field(:project_slug, :string)
      field(:assignee, :string)
      field(:active_states, {:array, :string}, default: ["Todo", "In Progress"])
      field(:terminal_states, {:array, :string}, default: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"])
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:kind, :endpoint, :api_key, :project_slug, :assignee, :active_states, :terminal_states],
        empty_values: []
      )
    end
  end

  defmodule Polling do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:interval_ms, :integer, default: 30_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:interval_ms], empty_values: [])
      |> validate_number(:interval_ms, greater_than: 0)
    end
  end

  defmodule Workspace do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:root, :string, default: Path.join(System.tmp_dir!(), "symphony_workspaces"))
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:root], empty_values: [])
    end
  end

  defmodule Worker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:ssh_hosts, {:array, :string}, default: [])
      field(:max_concurrent_agents_per_host, :integer)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:ssh_hosts, :max_concurrent_agents_per_host], empty_values: [])
      |> validate_number(:max_concurrent_agents_per_host, greater_than: 0)
    end
  end

  defmodule Agent do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    @primary_key false
    embedded_schema do
      field(:backend, :string, default: "codex")
      field(:stage_backends, :map, default: %{})
      field(:stage_models, :map, default: %{})
      field(:stage_reasoning_efforts, :map, default: %{})
      field(:max_concurrent_agents, :integer, default: 10)
      field(:max_turns, :integer, default: 20)
      field(:max_retry_backoff_ms, :integer, default: 300_000)
      field(:max_concurrent_agents_by_state, :map, default: %{})
    end

    @spec changeset(%__MODULE__{}, map(), [String.t()]) :: Ecto.Changeset.t()
    def changeset(schema, attrs, allowed_backends) do
      schema
      |> cast(
        attrs,
        [
          :backend,
          :stage_backends,
          :stage_models,
          :stage_reasoning_efforts,
          :max_concurrent_agents,
          :max_turns,
          :max_retry_backoff_ms,
          :max_concurrent_agents_by_state
        ],
        empty_values: []
      )
      |> update_change(:backend, &Schema.normalize_backend_name/1)
      |> Schema.validate_backend_name(:backend, allowed_backends)
      |> update_change(:stage_backends, &Schema.normalize_stage_backends/1)
      |> Schema.validate_stage_backends(:stage_backends, allowed_backends)
      |> update_change(:stage_models, &Schema.normalize_stage_string_map/1)
      |> Schema.validate_stage_string_map(:stage_models, "stage models must be non-empty strings")
      |> update_change(:stage_reasoning_efforts, &Schema.normalize_stage_string_map/1)
      |> Schema.validate_stage_string_map(
        :stage_reasoning_efforts,
        "stage reasoning efforts must be non-empty strings"
      )
      |> validate_number(:max_concurrent_agents, greater_than: 0)
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:max_retry_backoff_ms, greater_than: 0)
      |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
      |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
    end
  end

  defmodule Codex do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "codex app-server")
      field(:model, :string)
      field(:reasoning_effort, :string)

      field(:approval_policy, StringOrMap,
        default: %{
          "reject" => %{
            "sandbox_approval" => true,
            "rules" => true,
            "mcp_elicitations" => true
          }
        }
      )

      field(:thread_sandbox, :string, default: "workspace-write")
      field(:turn_sandbox_policy, :map)
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      field(:read_timeout_ms, :integer, default: 5_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :command,
          :model,
          :reasoning_effort,
          :approval_policy,
          :thread_sandbox,
          :turn_sandbox_policy,
          :turn_timeout_ms,
          :read_timeout_ms,
          :stall_timeout_ms
        ],
        empty_values: []
      )
      |> validate_required([:command])
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
    end
  end

  defmodule Acp do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    @primary_key false
    embedded_schema do
      field(:backends, :map, default: %{"claude-code" => %{"command" => "claude-agent-acp", "env" => %{}}})
      field(:bypass_permissions, :boolean, default: true)
      field(:read_timeout_ms, :integer, default: 5_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
      field(:turn_timeout_ms, :integer, default: 3_600_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:backends, :bypass_permissions, :read_timeout_ms, :stall_timeout_ms, :turn_timeout_ms], empty_values: [])
      |> update_change(:backends, &Schema.normalize_acp_backends/1)
      |> Schema.validate_acp_backends(:backends)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
      |> validate_number(:turn_timeout_ms, greater_than: 0)
    end
  end

  defmodule Hooks do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:after_create, :string)
      field(:before_run, :string)
      field(:after_run, :string)
      field(:before_remove, :string)
      field(:timeout_ms, :integer, default: 60_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:after_create, :before_run, :after_run, :before_remove, :timeout_ms], empty_values: [])
      |> validate_number(:timeout_ms, greater_than: 0)
    end
  end

  defmodule Observability do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:dashboard_enabled, :boolean, default: true)
      field(:refresh_ms, :integer, default: 1_000)
      field(:render_interval_ms, :integer, default: 16)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:dashboard_enabled, :refresh_ms, :render_interval_ms], empty_values: [])
      |> validate_number(:refresh_ms, greater_than: 0)
      |> validate_number(:render_interval_ms, greater_than: 0)
    end
  end

  defmodule Server do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:port, :integer)
      field(:host, :string, default: "127.0.0.1")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:port, :host], empty_values: [])
      |> validate_number(:port, greater_than_or_equal_to: 0)
    end
  end

  embedded_schema do
    embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:worker, Worker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:agent, Agent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
    embeds_one(:acp, Acp, on_replace: :update, defaults_to_struct: true)
    embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
    embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
  end

  @spec parse(map()) :: {:ok, %__MODULE__{}} | {:error, {:invalid_workflow_config, String.t()}}
  def parse(config) when is_map(config) do
    config
    |> normalize_keys()
    |> drop_nil_values()
    |> changeset()
    |> apply_action(:validate)
    |> case do
      {:ok, settings} ->
        {:ok, finalize_settings(settings)}

      {:error, changeset} ->
        {:error, {:invalid_workflow_config, format_errors(changeset)}}
    end
  end

  @spec resolve_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil) :: map()
  def resolve_turn_sandbox_policy(settings, workspace \\ nil) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        policy

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> expand_local_workspace_root()
        |> default_turn_sandbox_policy()
    end
  end

  @spec resolve_runtime_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_runtime_turn_sandbox_policy(settings, workspace \\ nil, opts \\ []) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        {:ok, policy}

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> default_runtime_turn_sandbox_policy(opts)
    end
  end

  @spec normalize_issue_state(String.t()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(state_name)
  end

  @doc false
  @spec normalize_state_limits(nil | map()) :: map()
  def normalize_state_limits(nil), do: %{}

  def normalize_state_limits(limits) when is_map(limits) do
    Enum.reduce(limits, %{}, fn {state_name, limit}, acc ->
      Map.put(acc, normalize_issue_state(to_string(state_name)), limit)
    end)
  end

  @doc false
  @spec normalize_backend_name(term()) :: String.t() | nil
  def normalize_backend_name(value), do: StageRouting.normalize_backend(value)

  @doc false
  @spec normalize_acp_backends(nil | map()) :: map()
  def normalize_acp_backends(nil), do: @default_acp_backends

  def normalize_acp_backends(backends) when is_map(backends) do
    normalized_backends =
      Enum.reduce(backends, %{}, fn {backend_name, backend_config}, acc ->
        case normalize_backend_name(backend_name) do
          nil ->
            acc

          normalized_backend ->
            Map.put(acc, normalized_backend, normalize_acp_backend_config(backend_config))
        end
      end)

    Map.merge(@default_acp_backends, normalized_backends, fn _backend_name, defaults, configured ->
      Map.merge(defaults, configured)
    end)
  end

  @doc false
  @spec normalize_stage_backends(nil | map()) :: map()
  def normalize_stage_backends(nil), do: %{}

  def normalize_stage_backends(stage_backends) when is_map(stage_backends) do
    Enum.reduce(stage_backends, %{}, fn {stage_name, backend_name}, acc ->
      case StageRouting.normalize_stage(stage_name) do
        nil ->
          acc

        normalized_stage ->
          Map.put(acc, normalized_stage, normalize_backend_name(backend_name))
      end
    end)
  end

  @doc false
  @spec normalize_stage_string_map(nil | map()) :: map()
  def normalize_stage_string_map(nil), do: %{}

  def normalize_stage_string_map(stage_values) when is_map(stage_values) do
    Enum.reduce(stage_values, %{}, fn {stage_name, value}, acc ->
      case {StageRouting.normalize_stage(stage_name), normalize_stage_string_value(value)} do
        {nil, _value} ->
          acc

        {normalized_stage, normalized_value} ->
          Map.put(acc, normalized_stage, normalized_value)
      end
    end)
  end

  @doc false
  @spec validate_state_limits(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_state_limits(changeset, field) do
    validate_change(changeset, field, fn ^field, limits ->
      Enum.flat_map(limits, fn {state_name, limit} ->
        cond do
          to_string(state_name) == "" ->
            [{field, "state names must not be blank"}]

          not is_integer(limit) or limit <= 0 ->
            [{field, "limits must be positive integers"}]

          true ->
            []
        end
      end)
    end)
  end

  @doc false
  @spec validate_backend_name(Ecto.Changeset.t(), atom(), [String.t()]) :: Ecto.Changeset.t()
  def validate_backend_name(changeset, field, allowed_backends) do
    validate_change(changeset, field, fn ^field, backend_name ->
      if is_binary(backend_name) and backend_name in allowed_backends do
        []
      else
        [{field, "must be one of #{backend_error_choices(allowed_backends)}"}]
      end
    end)
  end

  @doc false
  @spec validate_stage_backends(Ecto.Changeset.t(), atom(), [String.t()]) :: Ecto.Changeset.t()
  def validate_stage_backends(changeset, field, allowed_backends) do
    validate_change(changeset, field, fn ^field, stage_backends ->
      Enum.flat_map(stage_backends, fn {stage_name, backend_name} ->
        cond do
          to_string(stage_name) == "" ->
            [{field, "stage names must not be blank"}]

          not is_binary(backend_name) or backend_name not in allowed_backends ->
            [{field, "stage backends must be one of #{backend_error_choices(allowed_backends)}"}]

          true ->
            []
        end
      end)
    end)
  end

  @doc false
  @spec validate_stage_string_map(Ecto.Changeset.t(), atom(), String.t()) :: Ecto.Changeset.t()
  def validate_stage_string_map(changeset, field, value_error_message) do
    validate_change(changeset, field, fn ^field, stage_values ->
      Enum.flat_map(stage_values, fn {stage_name, value} ->
        cond do
          to_string(stage_name) == "" ->
            [{field, "stage names must not be blank"}]

          not is_binary(value) or String.trim(value) == "" ->
            [{field, value_error_message}]

          true ->
            []
        end
      end)
    end)
  end

  defp changeset(attrs) do
    allowed_backends = allowed_backend_names(attrs)

    %__MODULE__{}
    |> cast(attrs, [])
    |> cast_embed(:tracker, with: &Tracker.changeset/2)
    |> cast_embed(:polling, with: &Polling.changeset/2)
    |> cast_embed(:workspace, with: &Workspace.changeset/2)
    |> cast_embed(:worker, with: &Worker.changeset/2)
    |> cast_embed(:agent, with: &Agent.changeset(&1, &2, allowed_backends))
    |> cast_embed(:codex, with: &Codex.changeset/2)
    |> cast_embed(:acp, with: &Acp.changeset/2)
    |> cast_embed(:hooks, with: &Hooks.changeset/2)
    |> cast_embed(:observability, with: &Observability.changeset/2)
    |> cast_embed(:server, with: &Server.changeset/2)
  end

  defp finalize_settings(settings) do
    tracker = %{
      settings.tracker
      | api_key: resolve_secret_setting(settings.tracker.api_key, System.get_env("LINEAR_API_KEY")),
        assignee: resolve_secret_setting(settings.tracker.assignee, System.get_env("LINEAR_ASSIGNEE"))
    }

    workspace = %{
      settings.workspace
      | root: resolve_path_value(settings.workspace.root, Path.join(System.tmp_dir!(), "symphony_workspaces"))
    }

    codex = %{
      settings.codex
      | approval_policy: normalize_keys(settings.codex.approval_policy),
        turn_sandbox_policy: normalize_optional_map(settings.codex.turn_sandbox_policy)
    }

    acp = %{
      settings.acp
      | backends: finalize_acp_backends(settings.acp.backends)
    }

    %{settings | tracker: tracker, workspace: workspace, codex: codex, acp: acp}
  end

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_optional_map(nil), do: nil
  defp normalize_optional_map(value) when is_map(value), do: normalize_keys(value)

  defp allowed_backend_names(attrs) do
    acp_backend_names =
      attrs
      |> Map.get("acp", %{})
      |> Map.get("backends", %{})
      |> case do
        backends when is_map(backends) ->
          backends
          |> Map.keys()
          |> Enum.map(&normalize_backend_name/1)
          |> Enum.reject(&is_nil/1)

        _ ->
          []
      end

    (@builtin_backend_names ++ Map.keys(@default_acp_backends) ++ acp_backend_names)
    |> Enum.uniq()
  end

  defp normalize_acp_backend_config(command) when is_binary(command) do
    %{"command" => command, "env" => %{}}
  end

  defp normalize_acp_backend_config(config) when is_map(config) do
    config
    |> normalize_keys()
    |> Map.update("env", %{}, fn
      env when is_map(env) -> normalize_keys(env)
      _ -> %{}
    end)
  end

  defp normalize_acp_backend_config(_config), do: %{}

  defp finalize_acp_backends(nil), do: normalize_acp_backends(nil)

  defp finalize_acp_backends(backends) when is_map(backends) do
    backends
    |> normalize_acp_backends()
    |> Enum.into(%{}, fn {backend_name, backend_config} ->
      {backend_name, finalize_acp_backend_config(backend_config)}
    end)
  end

  defp finalize_acp_backend_config(config) when is_map(config) do
    config
    |> normalize_keys()
    |> Map.update("env", %{}, &finalize_acp_backend_env/1)
  end

  defp finalize_acp_backend_env(env) when is_map(env) do
    Enum.into(env, %{}, fn {key, value} ->
      normalized_value =
        case resolve_env_value(to_string(value), to_string(value)) do
          nil -> ""
          resolved -> to_string(resolved)
        end

      {to_string(key), normalized_value}
    end)
  end

  defp finalize_acp_backend_env(_env), do: %{}

  @doc false
  @spec validate_acp_backends(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_acp_backends(changeset, field) do
    validate_change(changeset, field, fn ^field, backends ->
      Enum.flat_map(backends, fn {backend_name, backend_config} ->
        validate_acp_backend_config(field, backend_name, backend_config)
      end)
    end)
  end

  defp validate_acp_backend_config(field, backend_name, backend_config) when is_map(backend_config) do
    command = Map.get(backend_config, "command")
    env = Map.get(backend_config, "env", %{})

    []
    |> maybe_add_acp_backend_error(blank_backend_name?(backend_name), field, "ACP backend names must not be blank")
    |> maybe_add_acp_backend_error(not non_empty_binary?(command), field, "ACP backend command must be a non-empty string")
    |> maybe_add_acp_backend_error(not valid_env_map?(env), field, "ACP backend env must be a string map")
    |> maybe_add_acp_backend_error(
      invalid_positive_integer?(Map.get(backend_config, "turn_timeout_ms")),
      field,
      "ACP backend turn_timeout_ms must be a positive integer"
    )
    |> maybe_add_acp_backend_error(
      invalid_positive_integer?(Map.get(backend_config, "read_timeout_ms")),
      field,
      "ACP backend read_timeout_ms must be a positive integer"
    )
    |> maybe_add_acp_backend_error(
      invalid_non_negative_integer?(Map.get(backend_config, "stall_timeout_ms")),
      field,
      "ACP backend stall_timeout_ms must be a non-negative integer"
    )
    |> maybe_add_acp_backend_error(
      invalid_boolean?(Map.get(backend_config, "bypass_permissions")),
      field,
      "ACP backend bypass_permissions must be a boolean"
    )
    |> maybe_add_acp_backend_error(
      invalid_optional_binary?(Map.get(backend_config, "model")),
      field,
      "ACP backend model must be a non-empty string"
    )
    |> maybe_add_acp_backend_error(
      invalid_optional_binary?(Map.get(backend_config, "mode")),
      field,
      "ACP backend mode must be a non-empty string"
    )
  end

  defp validate_acp_backend_config(field, _backend_name, _backend_config) do
    [{field, "ACP backend entries must be maps or command strings"}]
  end

  defp maybe_add_acp_backend_error(errors, true, field, message), do: [{field, message} | errors]
  defp maybe_add_acp_backend_error(errors, false, _field, _message), do: errors

  defp normalize_stage_string_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> value
      trimmed -> trimmed
    end
  end

  defp normalize_stage_string_value(value), do: value

  defp backend_error_choices(allowed_backends) do
    allowed_backends
    |> Enum.sort()
    |> Enum.join(", ")
  end

  defp blank_backend_name?(backend_name), do: not non_empty_binary?(backend_name)

  defp non_empty_binary?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_empty_binary?(_value), do: false

  defp valid_env_map?(env) when is_map(env) do
    Enum.all?(env, fn {key, value} ->
      non_empty_binary?(to_string(key)) and is_binary(value)
    end)
  end

  defp valid_env_map?(_env), do: false

  defp invalid_positive_integer?(nil), do: false
  defp invalid_positive_integer?(value), do: not (is_integer(value) and value > 0)

  defp invalid_non_negative_integer?(nil), do: false
  defp invalid_non_negative_integer?(value), do: not (is_integer(value) and value >= 0)

  defp invalid_boolean?(nil), do: false
  defp invalid_boolean?(value), do: not is_boolean(value)

  defp invalid_optional_binary?(nil), do: false
  defp invalid_optional_binary?(value), do: not non_empty_binary?(value)

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp drop_nil_values(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      case drop_nil_values(nested) do
        nil -> acc
        normalized -> Map.put(acc, key, normalized)
      end
    end)
  end

  defp drop_nil_values(value) when is_list(value), do: Enum.map(value, &drop_nil_values/1)
  defp drop_nil_values(value), do: value

  defp resolve_secret_setting(nil, fallback), do: normalize_secret_value(fallback)

  defp resolve_secret_setting(value, fallback) when is_binary(value) do
    case resolve_env_value(value, fallback) do
      resolved when is_binary(resolved) -> normalize_secret_value(resolved)
      resolved -> resolved
    end
  end

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      "" ->
        default

      path ->
        path
    end
  end

  defp resolve_env_value(value, fallback) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} ->
        case System.get_env(env_name) do
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end

      :error ->
        value
    end
  end

  defp normalize_path_token(value) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> value
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(env_name) do
    case System.get_env(env_name) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp normalize_secret_value(_value), do: nil

  defp default_turn_sandbox_policy(workspace) do
    %{
      "type" => "workspaceWrite",
      "writableRoots" => [workspace],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, opts) when is_binary(workspace_root) do
    if Keyword.get(opts, :remote, false) do
      {:ok, default_turn_sandbox_policy(workspace_root)}
    else
      with expanded_workspace_root <- expand_local_workspace_root(workspace_root),
           {:ok, canonical_workspace_root} <- PathSafety.canonicalize(expanded_workspace_root) do
        {:ok, default_turn_sandbox_policy(canonical_workspace_root)}
      end
    end
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, _opts) do
    {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, workspace_root}}}
  end

  defp default_workspace_root(workspace, _fallback) when is_binary(workspace) and workspace != "",
    do: workspace

  defp default_workspace_root(nil, fallback), do: fallback
  defp default_workspace_root("", fallback), do: fallback
  defp default_workspace_root(workspace, _fallback), do: workspace

  defp expand_local_workspace_root(workspace_root)
       when is_binary(workspace_root) and workspace_root != "" do
    Path.expand(workspace_root)
  end

  defp expand_local_workspace_root(_workspace_root) do
    Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))
  end

  defp format_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors, prefix \\ nil)

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix =
        case prefix do
          nil -> to_string(key)
          current -> current <> "." <> to_string(key)
        end

      flatten_errors(value, next_prefix)
    end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    Enum.map(errors, &(prefix <> " " <> &1))
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", error_value_to_string(value))
    end)
  end

  defp error_value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp error_value_to_string(value), do: inspect(value)
end
