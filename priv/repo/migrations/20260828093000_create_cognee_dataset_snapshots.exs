defmodule Home.Repo.Migrations.CreateCogneeDatasetSnapshots do
  use Ecto.Migration

  def change do
    create table(:cognee_dataset_snapshots, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :dataset_id, :string, null: false
      add :dataset_name, :string, null: false
      add :item_count, :bigint, null: false, default: 0
      add :recent_day_count, :bigint, null: false, default: 0
      add :recent_week_count, :bigint, null: false, default: 0
      add :latest_activity_at, :utc_datetime_usec
      add :captured_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:cognee_dataset_snapshots, [:dataset_id, :captured_at])
    create index(:cognee_dataset_snapshots, [:captured_at])
  end
end
