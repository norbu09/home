defmodule Home.Memory.InsightsTest do
  use Home.DataCase, async: false

  alias Home.Memory
  alias Home.Memory.Insights

  test "areas/0 reports per-scope stats from recollect entries" do
    {:ok, _} = Memory.remember("insights areas probe one", scope: "home")
    {:ok, _} = Memory.remember("insights areas probe two", scope: "home")

    areas = Insights.areas()
    assert [%{} = home] = Enum.filter(areas, &(&1.dataset_name == "home"))
    assert home.item_count >= 2
    assert home.recent_day_count == home.item_count
    assert home.recent_week_count == home.item_count
    assert %DateTime{} = home.latest_activity_at
  end

  test "build/1 derives insight rows from stats" do
    now = DateTime.utc_now()

    stats = [
      %{
        dataset_id: "home",
        dataset_name: "home",
        item_count: 10,
        recent_day_count: 3,
        recent_week_count: 5,
        latest_activity_at: now
      },
      %{
        dataset_id: "ops_center",
        dataset_name: "ops_center",
        item_count: 40,
        recent_day_count: 0,
        recent_week_count: 2,
        latest_activity_at: DateTime.add(now, -3_600, :second)
      }
    ]

    insights = Insights.build(stats)
    ids = Enum.map(insights, & &1.id)

    assert "recollect-growth" in ids
    assert "recollect-scale" in ids
    assert "recollect-active" in ids
    assert "recollect-coverage" in ids
    assert Enum.all?(insights, &(&1.source == "recollect"))
  end

  test "build/1 is empty with no areas" do
    assert Insights.build([]) == []
  end
end
