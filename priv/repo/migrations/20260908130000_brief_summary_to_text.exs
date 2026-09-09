defmodule Home.Repo.Migrations.BriefSummaryToText do
  use Ecto.Migration

  def change do
    alter table(:briefs) do
      # Real agent brief summaries exceed varchar(500) — a completed sweep
      # with a proper one-paragraph verdict fails to persist otherwise.
      modify :summary, :text, from: :string
    end
  end
end
