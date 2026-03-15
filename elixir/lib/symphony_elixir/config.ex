defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.StageRouting
  alias SymphonyElixir.Workflow

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @type acp_backend_runtime_settings :: %{
          command: String.t(),
          env: map(),
          read_timeout_ms: pos_integer(),
          stall_timeout_ms: non_neg_integer(),
          turn_timeout_ms: pos_integer(),
          bypass_permissions: boolean(),
          model: String.t() | nil,
          mode: String.t() | nil
        }

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec agent_backend() :: String.t()
  def agent_backend do
    settings!()
    |> StageRouting.default_backend()
  end

  @spec backend_for_stage(String.t() | nil) :: String.t()
  def backend_for_stage(stage) do
    settings!()
    |> StageRouting.backend_for_stage(stage)
  end

  @spec stage_model_override(String.t() | nil) :: String.t() | nil
  def stage_model_override(stage) when is_binary(stage) do
    settings!().agent.stage_models
    |> Map.get(StageRouting.normalize_stage(stage))
  end

  def stage_model_override(_stage), do: nil

  @spec stage_reasoning_effort_override(String.t() | nil) :: String.t() | nil
  def stage_reasoning_effort_override(stage) when is_binary(stage) do
    settings!().agent.stage_reasoning_efforts
    |> Map.get(StageRouting.normalize_stage(stage))
  end

  def stage_reasoning_effort_override(_stage), do: nil

  @spec codex_model(String.t() | nil) :: String.t() | nil
  def codex_model(stage \\ nil) do
    stage_model_override(stage) || settings!().codex.model
  end

  @spec codex_reasoning_effort(String.t() | nil) :: String.t() | nil
  def codex_reasoning_effort(stage \\ nil) do
    stage_reasoning_effort_override(stage) || settings!().codex.reasoning_effort
  end

  @spec routed_stages(map()) :: [StageRouting.route()]
  def routed_stages(issue) when is_map(issue) do
    StageRouting.routed_stages(issue, settings!())
  end

  @spec acp_backend?(term()) :: boolean()
  def acp_backend?(backend_name) do
    normalized_backend = StageRouting.normalize_backend(backend_name)

    normalized_backend != nil and normalized_backend in Map.keys(settings!().acp.backends)
  end

  @spec acp_backend_names() :: [String.t()]
  def acp_backend_names do
    settings!().acp.backends |> Map.keys() |> Enum.sort()
  end

  @spec acp_backend_config(term()) :: acp_backend_runtime_settings() | nil
  def acp_backend_config(backend_name) do
    normalized_backend = StageRouting.normalize_backend(backend_name)

    with backend when is_binary(backend) <- normalized_backend,
         %{} = config <- Map.get(settings!().acp.backends, backend) do
      settings = settings!().acp

      %{
        command: Map.fetch!(config, "command"),
        env: Map.get(config, "env", %{}),
        read_timeout_ms: Map.get(config, "read_timeout_ms", settings.read_timeout_ms),
        stall_timeout_ms: Map.get(config, "stall_timeout_ms", settings.stall_timeout_ms),
        turn_timeout_ms: Map.get(config, "turn_timeout_ms", settings.turn_timeout_ms),
        bypass_permissions: Map.get(config, "bypass_permissions", settings.bypass_permissions),
        model: Map.get(config, "model"),
        mode: Map.get(config, "mode")
      }
    else
      _ -> nil
    end
  end

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings() do
      with {:ok, turn_sandbox_policy} <-
             Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
        {:ok,
         %{
           approval_policy: settings.codex.approval_policy,
           thread_sandbox: settings.codex.thread_sandbox,
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  defp validate_semantics(settings) do
    cond do
      is_nil(settings.tracker.kind) ->
        {:error, :missing_tracker_kind}

      settings.tracker.kind not in ["linear", "memory", "stub"] ->
        {:error, {:unsupported_tracker_kind, settings.tracker.kind}}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.api_key) ->
        {:error, :missing_linear_api_token}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.project_slug) ->
        {:error, :missing_linear_project_slug}

      true ->
        :ok
    end
  end

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end
end
