defmodule SymphonyElixir.StageRouting do
  @moduledoc """
  Resolves stage-aware backend routing for issues from workflow config and normalized issue labels.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue

  @stage_order ["backend", "frontend", "integration"]

  @type backend_name :: String.t()
  @type route :: %{stage: String.t() | nil, backend: backend_name()}

  @spec normalize_backend(term()) :: backend_name() | nil
  def normalize_backend(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_backend()

  def normalize_backend(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "claude" -> "claude-code"
      "" -> nil
      backend -> backend
    end
  end

  def normalize_backend(_value), do: nil

  @spec normalize_stage(term()) :: String.t() | nil
  def normalize_stage(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_stage()

  def normalize_stage(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      stage -> stage
    end
  end

  def normalize_stage(_value), do: nil

  @spec default_backend(Schema.t()) :: backend_name()
  def default_backend(%Schema{} = settings) do
    normalize_backend(settings.agent.backend) || "codex"
  end

  @spec backend_for_stage(Schema.t(), String.t() | nil) :: backend_name()
  def backend_for_stage(%Schema{} = settings, nil), do: default_backend(settings)

  def backend_for_stage(%Schema{} = settings, stage) when is_binary(stage) do
    normalized_stage = normalize_stage(stage)

    settings.agent.stage_backends
    |> Map.get(normalized_stage, default_backend(settings))
    |> normalize_backend()
    |> Kernel.||("codex")
  end

  @spec routed_stages(Issue.t() | map(), Schema.t()) :: [route()]
  def routed_stages(%Issue{} = issue, %Schema{} = settings) do
    issue
    |> Map.from_struct()
    |> routed_stages(settings)
  end

  def routed_stages(%{labels: labels}, %Schema{} = settings) when is_list(labels) do
    normalized_labels =
      labels
      |> Enum.map(&normalize_stage/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    stages =
      ordered_stages(settings.agent.stage_backends)
      |> Enum.filter(&MapSet.member?(normalized_labels, &1))

    case stages do
      [] ->
        [%{stage: nil, backend: default_backend(settings)}]

      stage_names ->
        Enum.map(stage_names, fn stage ->
          %{stage: stage, backend: backend_for_stage(settings, stage)}
        end)
    end
  end

  def routed_stages(_issue, %Schema{} = settings), do: [%{stage: nil, backend: default_backend(settings)}]

  @spec stage_labeled?([route()]) :: boolean()
  def stage_labeled?([%{stage: stage} | _rest]) when is_binary(stage), do: true
  def stage_labeled?(_routes), do: false

  defp ordered_stages(stage_backends) when is_map(stage_backends) do
    configured_stages =
      stage_backends
      |> Map.keys()
      |> Enum.map(&normalize_stage/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(&1 in @stage_order))
      |> Enum.sort()

    @stage_order ++ configured_stages
  end
end
