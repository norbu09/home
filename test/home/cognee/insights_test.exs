defmodule Home.Cognee.InsightsTest do
  use ExUnit.Case, async: true

  alias Home.Cognee.Insights

  test "derives growth, scale, activity, and overlap signals" do
    now = DateTime.utc_now()

    stats = [
      stat("one", "ocp-cafemanager", 40, 8, 30, now),
      stat("two", "ocp-cafe-manager", 12, 2, 12, DateTime.add(now, -3_600)),
      stat("three", "ocp-ops-center", 70, 5, 20, DateTime.add(now, -7_200))
    ]

    previous = %{
      "one" => %{item_count: 35},
      "two" => %{item_count: 12},
      "three" => %{item_count: 70}
    }

    insights = Insights.build(stats, previous)

    assert Enum.find(insights, &(&1.id == "cognee-growth")).title ==
             "Growth leader: Cafemanager"

    assert Enum.find(insights, &(&1.id == "cognee-scale")).title ==
             "Largest memory: Ops Center"

    assert Enum.find(insights, &(&1.id == "cognee-active")).notes =~ "just now"
    assert Enum.find(insights, &(&1.id == "cognee-overlap")).notes =~ "split recall"
  end

  defp stat(id, name, count, day_count, week_count, latest_activity_at) do
    %{
      dataset_id: id,
      dataset_name: name,
      item_count: count,
      recent_day_count: day_count,
      recent_week_count: week_count,
      latest_activity_at: latest_activity_at
    }
  end
end
