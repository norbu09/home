defmodule Home.Cognee.Insights do
  @moduledoc "Derives tactical signals from Cognee dataset activity."

  def build([], _previous), do: []

  def build(stats, previous) do
    [
      growth_insight(stats, previous),
      largest_insight(stats),
      activity_insight(stats),
      coverage_insight(stats)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp growth_insight(stats, previous) do
    growth =
      Enum.map(stats, fn stat ->
        prior_count =
          previous
          |> Map.get(stat.dataset_id, %{item_count: stat.item_count})
          |> Map.get(:item_count)

        Map.put(stat, :growth, max(stat.item_count - prior_count, 0))
      end)

    leader =
      Enum.max_by(growth, &{&1.growth, &1.recent_day_count, &1.recent_week_count}, fn -> nil end)

    cond do
      is_nil(leader) ->
        nil

      leader.growth > 0 ->
        insight(
          "growth",
          "Growth leader: #{display_name(leader.dataset_name)}",
          "Added #{leader.growth} memory records since the last scan; #{leader.item_count} records are now indexed.",
          1
        )

      leader.recent_day_count > 0 ->
        insight(
          "growth",
          "Growing now: #{display_name(leader.dataset_name)}",
          "Received #{leader.recent_day_count} memory records in the last 24 hours; #{leader.item_count} records are now indexed.",
          1
        )

      leader.recent_week_count > 0 ->
        insight(
          "growth",
          "Growing this week: #{display_name(leader.dataset_name)}",
          "Received #{leader.recent_week_count} memory records in the last 7 days; #{leader.item_count} records are now indexed.",
          1
        )

      true ->
        nil
    end
  end

  defp largest_insight(stats) do
    largest = Enum.max_by(stats, & &1.item_count)

    insight(
      "scale",
      "Largest memory: #{display_name(largest.dataset_name)}",
      "#{largest.item_count} records, #{percent(largest.item_count, total_items(stats))}% of all indexed Cognee material.",
      2
    )
  end

  defp activity_insight(stats) do
    case stats
         |> Enum.reject(&is_nil(&1.latest_activity_at))
         |> Enum.max_by(& &1.latest_activity_at, DateTime, fn -> nil end) do
      nil ->
        nil

      latest ->
        insight(
          "active",
          "Freshest context: #{display_name(latest.dataset_name)}",
          "Last memory activity #{relative_time(latest.latest_activity_at)}; #{latest.recent_week_count} records landed in the last 7 days.",
          2
        )
    end
  end

  defp coverage_insight(stats) do
    duplicates =
      stats
      |> Enum.group_by(&normalized_name(&1.dataset_name))
      |> Enum.find(fn {_name, entries} -> length(entries) > 1 end)

    case duplicates do
      {_name, entries} ->
        names = entries |> Enum.map(& &1.dataset_name) |> Enum.sort() |> Enum.join(" and ")

        insight(
          "overlap",
          "Dataset overlap detected",
          "#{names} normalize to the same area; consider consolidating them to avoid split recall.",
          1
        )

      nil ->
        insight(
          "coverage",
          "Memory coverage",
          "#{length(stats)} knowledge areas hold #{total_items(stats)} indexed records across Cognee.",
          3
        )
    end
  end

  defp insight(signal, title, notes, priority) do
    %{
      id: "cognee-#{signal}",
      signal: signal,
      title: title,
      notes: notes,
      priority: priority,
      source: "cognee"
    }
  end

  defp total_items(stats), do: Enum.sum(Enum.map(stats, & &1.item_count))
  defp percent(_part, 0), do: 0
  defp percent(part, total), do: round(part / total * 100)

  defp display_name(name) do
    name
    |> String.replace_prefix("ocp-", "")
    |> String.replace("-", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp normalized_name(name) do
    name
    |> String.replace_prefix("ocp-", "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/, "")
  end

  defp relative_time(datetime) do
    seconds = max(DateTime.diff(DateTime.utc_now(), datetime, :second), 0)

    cond do
      seconds < 60 -> "just now"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end
end
