defmodule Home.Repo.Migrations.AddToolToLlmUsageLogs do
  use Ecto.Migration

  def change do
    alter table(:llm_usage_logs) do
      add :tool, :string
    end

    create index(:llm_usage_logs, [:tool, :usage_date])
  end
end
