defmodule Home.Repo.Migrations.AddEncryptedSecrets do
  use Ecto.Migration

  def up do
    create table(:secrets, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :service, :text, null: false
      add :key, :text, null: false
      add :encrypted_value, :binary, null: false
      add :description, :text
      add :is_active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:secrets, [:service, :key], name: "secrets_unique_service_key_index")
  end

  def down do
    drop_if_exists unique_index(:secrets, [:service, :key],
                     name: "secrets_unique_service_key_index"
                   )

    drop table(:secrets)
  end
end
