defmodule Home.Repo.Migrations.CreateLlmModelRoutes do
  use Ecto.Migration

  def change do
    create table(:llm_model_routes, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :model_group, :string, null: false
      add :provider, :string, null: false
      add :model, :string, null: false
      add :order, :integer, null: false, default: 1
      add :priority, :integer, null: false, default: 0
      add :input_cost_per_million, :decimal
      add :output_cost_per_million, :decimal
      add :enabled, :boolean, null: false, default: true
      add :notes, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:llm_model_routes, [:model_group, :provider, :model])
    create index(:llm_model_routes, [:model_group, :enabled, :order])
    create index(:llm_model_routes, [:provider, :enabled])
  end
end
