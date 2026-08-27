defmodule Home.Repo.Migrations.CreateLlmUsageLogs do
  use Ecto.Migration

  def change do
    create table(:llm_usage_logs, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :usage_date, :date, null: false
      add :project, :string, null: false
      add :provider, :string, null: false
      add :model, :string, null: false
      add :calls, :bigint, null: false, default: 0
      add :input_tokens, :bigint, null: false, default: 0
      add :output_tokens, :bigint, null: false, default: 0
      add :cost_micros, :bigint, null: false, default: 0
      add :latency_total_ms, :bigint, null: false, default: 0
      add :last_seen_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:llm_usage_logs, [:usage_date])
    create index(:llm_usage_logs, [:project, :usage_date])
    create index(:llm_usage_logs, [:provider, :usage_date])
  end
end
