defmodule SymphonyElixir.Config.Schema.Acp do
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
