defmodule Home.Secrets.Secret do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "secrets" do
    field :service, :string
    field :key, :string
    field :encrypted_value, :binary
    field :description, :string
    field :is_active, :boolean, default: true

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(secret, attrs) do
    secret
    |> cast(attrs, [:service, :key, :encrypted_value, :description, :is_active])
    |> validate_required([:service, :key, :encrypted_value, :is_active])
    |> unique_constraint([:service, :key], name: :secrets_unique_service_key_index)
  end
end
