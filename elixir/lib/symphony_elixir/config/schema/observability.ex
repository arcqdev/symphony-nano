defmodule SymphonyElixir.Config.Schema.Observability do
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
