defmodule Home.MemoryTest do
  use Home.DataCase, async: false

  alias Home.Memory

  test "remember/2 stores an entry scoped by name" do
    assert {:ok, entry} =
             Memory.remember("home memory facade test note", scope: "home", tags: ["test"])

    assert entry.content == "home memory facade test note"
    assert entry.scope_id == Memory.scope_uuid("home")
  end

  test "search/2 finds entries in the scope" do
    {:ok, _} = Memory.remember("unique purple giraffe keyword", scope: "home")

    assert {:ok, results} = Memory.search("purple giraffe", scope: "home")

    # Embedding search returns entry maps; the ILIKE fallback returns
    # {:text, markdown} tuples — accept either shape.
    assert Enum.any?(results, fn
             %{content: content} -> content =~ "purple giraffe"
             {:text, markdown} -> markdown =~ "purple giraffe"
           end)
  end

  test "source_exists?/2 detects deterministic source ids" do
    refute Memory.source_exists?("home", "test:nonexistent")

    {:ok, _} =
      Memory.remember("dedup probe", scope: "home", source: "agent", source_id: "test:probe")

    assert Memory.source_exists?("home", "test:probe")
    refute Memory.source_exists?("other", "test:probe")
  end
end
