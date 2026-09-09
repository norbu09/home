defmodule Home.Repo.Migrations.AddBackendToBriefPrompts do
  use Ecto.Migration

  def change do
    alter table(:brief_prompts) do
      add :backend, :string, null: false, default: "llm"
    end
  end
end
