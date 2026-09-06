defmodule Home.Brief.InsightsTest do
  use Home.DataCase, async: false

  import Ecto.Query

  alias Home.Brief
  alias Home.Brief.Insights
  alias Home.Brief.Conversation

  setup do
    prompt =
      Brief.create_prompt!(%{
        name: "Insights Prompt",
        slug: "insights-prompt",
        schedule: %{"at" => "08:00"},
        system_prompt: "s",
        user_prompt: "u",
        priority: 10
      })

    %{prompt: prompt}
  end

  test "aggregates per-prompt runs, failures, and averages", %{prompt: prompt} do
    {:ok, good} = Brief.create(%{prompt_id: prompt.id, status: "completed", outcome: "ok"})
    {:ok, _} = Brief.create(%{prompt_id: prompt.id, status: "completed", outcome: "ok"})
    {:ok, _} = Brief.create(%{prompt_id: prompt.id, status: "failed", error: "boom"})

    _ = Brief.update_brief(good, %{completed_at: DateTime.utc_now()})

    rows = Insights.by_prompt()
    assert [row] = rows
    assert row.prompt.slug == "insights-prompt"
    assert row.runs == 3
    assert row.completed == 2
    assert row.failed == 1
    assert %DateTime{} = row.last_completed_at
  end

  test "only counts briefs within the last 30 days", %{prompt: prompt} do
    {:ok, _} = Brief.create(%{prompt_id: prompt.id, status: "completed", outcome: "recent"})

    {:ok, old} = Brief.create(%{prompt_id: prompt.id, status: "completed", outcome: "old"})

    from(c in Conversation, where: c.id == ^old.id)
    |> Home.Repo.update_all(set: [inserted_at: DateTime.add(DateTime.utc_now(), -40, :day)])

    rows = Insights.by_prompt()
    assert [row] = rows
    assert row.runs == 1
  end
end
