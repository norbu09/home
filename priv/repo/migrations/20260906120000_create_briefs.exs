defmodule Home.Repo.Migrations.CreateBriefs do
  use Ecto.Migration

  def change do
    create table(:brief_prompts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :category, :string, null: false, default: "custom"
      add :system_prompt, :text, null: false
      add :user_prompt, :text, null: false
      add :schedule, :map, null: false, default: "{}"
      add :enabled, :boolean, null: false, default: true
      add :run_weekends, :boolean, null: false, default: false
      add :priority, :integer, null: false, default: 100
      add :model, :string
      add :metadata, :map, null: false, default: "{}"
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:brief_prompts, [:slug])

    create table(:briefs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :prompt_id, references(:brief_prompts, type: :binary_id), null: false
      add :status, :string, null: false, default: "pending"
      add :outcome, :text
      add :summary, :string, size: 500
      add :next_steps, {:array, :string}, null: false, default: "{}"
      add :action_items, {:array, :map}, null: false, default: "{}"
      add :reviewed_at, :utc_datetime_usec
      add :review_notes, :text
      add :error, :text
      add :scheduled_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :model_used, :string
      add :cost_usd, :float
      add :number, :string
      add :retried_from_id, references(:briefs, type: :binary_id)
      add :metadata, :map, null: false, default: "{}"
      timestamps(type: :utc_datetime_usec)
    end

    create index(:briefs, [:status, :inserted_at])
    create index(:briefs, [:prompt_id])
    create index(:briefs, [:reviewed_at])
    create unique_index(:briefs, [:number])

    create table(:brief_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :brief_id, references(:briefs, type: :binary_id), null: false
      add :role, :string, null: false
      add :content, :text, null: false
      add :cost_usd, :float
      add :model_used, :string
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:brief_messages, [:brief_id, :inserted_at])
  end
end
