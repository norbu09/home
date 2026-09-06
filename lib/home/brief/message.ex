defmodule Home.Brief.Message do
  @moduledoc """
  A single turn within a brief conversation: system, user, or assistant.
  Assistant turns carry the model used and any cost.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @roles ~w(system user assistant)

  schema "brief_messages" do
    field :role, :string
    field :content, :string
    field :cost_usd, :float
    field :model_used, :string

    belongs_to :brief, Home.Brief.Conversation, foreign_key: :brief_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:brief_id, :role, :content, :cost_usd, :model_used])
    |> validate_required([:brief_id, :role, :content])
    |> validate_inclusion(:role, @roles)
  end
end
