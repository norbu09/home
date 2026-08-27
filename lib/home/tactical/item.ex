defmodule Home.Tactical.Item do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "tactical_items" do
    field :kind, :string
    field :title, :string
    field :notes, :string
    field :status, :string, default: "active"
    field :priority, :integer, default: 2
    field :starts_at, :utc_datetime_usec
    field :due_on, :date
    field :source, :string, default: "manual"

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [:kind, :title, :notes, :status, :priority, :starts_at, :due_on, :source])
    |> validate_required([:kind, :title, :status, :priority, :source])
    |> validate_inclusion(:kind, ~w(goal meeting insight))
    |> validate_inclusion(:status, ~w(active completed dismissed))
    |> validate_inclusion(:priority, 1..3)
    |> validate_length(:title, max: 180)
  end
end
