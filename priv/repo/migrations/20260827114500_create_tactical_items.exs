defmodule Home.Repo.Migrations.CreateTacticalItems do
  use Ecto.Migration

  def change do
    create table(:tactical_items, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :kind, :string, null: false
      add :title, :string, null: false
      add :notes, :text
      add :status, :string, null: false, default: "active"
      add :priority, :integer, null: false, default: 2
      add :starts_at, :utc_datetime_usec
      add :due_on, :date
      add :source, :string, null: false, default: "manual"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:tactical_items, [:kind, :status])
    create index(:tactical_items, [:starts_at])
  end
end
