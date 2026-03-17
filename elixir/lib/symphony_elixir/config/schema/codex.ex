defmodule SymphonyElixir.Config.Schema.Codex do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias SymphonyElixir.Config.Schema.StringOrMap

  @primary_key false
  embedded_schema do
    field(:command, :string, default: "codex app-server")
    field(:model, :string)
    field(:reasoning_effort, :string)
    field(:approval_policy, StringOrMap, default: "never")
    field(:thread_sandbox, :string)
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
