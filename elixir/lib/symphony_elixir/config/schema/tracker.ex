defmodule SymphonyElixir.Config.Schema.Tracker do
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
    field(:human_review_state, :string)
    field(:active_states, {:array, :string}, default: ["Todo", "In Progress"])
    field(:terminal_states, {:array, :string}, default: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"])
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(
      attrs,
      [:kind, :endpoint, :api_key, :project_slug, :assignee, :human_review_state, :active_states, :terminal_states],
      empty_values: []
    )
  end
end
