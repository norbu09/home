defmodule Home.ActivityFocusTest do
  use ExUnit.Case, async: true

  alias Home.ActivityFocus

  test "merges router, Git, and Cognee names into one ranked workstream" do
    now = DateTime.utc_now()

    router = [
      %{
        id: "ops_center",
        name: "Ops Center",
        calls: 12,
        input_tokens: 100,
        output_tokens: 20,
        cost_usd: 0.2,
        last_seen_at: now
      }
    ]

    git = [%{id: "ops_center", name: "Ops Center", commit_count: 3, latest_at: now}]

    cognee = [
      %{
        dataset_name: "ocp-ops-center",
        item_count: 50,
        recent_day_count: 4,
        recent_week_count: 8,
        latest_activity_at: now
      }
    ]

    assert [focus] = ActivityFocus.build(router, git, cognee)
    assert focus.id == "ops_center"
    assert focus.signal_count == 3
    assert focus.router_calls == 12
    assert focus.commits == 3
    assert focus.memory_activity == 4
  end
end
