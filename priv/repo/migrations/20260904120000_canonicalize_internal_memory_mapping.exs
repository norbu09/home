defmodule Home.Repo.Migrations.CanonicalizeInternalMemoryMapping do
  use Ecto.Migration

  @unknown_scope_id "ad921d60-4863-3625-8809-553a3db49a4a"
  @shared_scope_id "9e81e7b9-63c7-3363-a2fb-3eefcfecfc0e"

  def up do
    execute("""
    UPDATE recollect_entries
    SET scope_id = '#{@shared_scope_id}',
        metadata = jsonb_set(metadata, '{scope}', '"shared"', true),
        source_id = replace(source_id, ':unknown:', ':shared:')
    WHERE scope_id = '#{@unknown_scope_id}'
       OR metadata->>'scope' = 'unknown'
    """)

    execute("UPDATE llm_usage_logs SET tool = 'memory' WHERE tool = 'cognee'")
  end

  def down do
    raise "canonical memory mappings cannot be safely reversed"
  end
end
