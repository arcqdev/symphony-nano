defmodule SymphonyElixir.Config.Schema.Agent do
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
    field(:max_input_tokens, :integer, default: 4_000_000)
    field(:max_output_tokens, :integer, default: 400_000)
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
        :max_concurrent_agents_by_state,
        :max_input_tokens,
        :max_output_tokens
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
    |> validate_number(:max_input_tokens, greater_than: 0)
    |> validate_number(:max_output_tokens, greater_than: 0)
    |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
    |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
  end
end
