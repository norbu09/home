defmodule Home.Memory.Insights do
  @moduledoc """
  Derives tactical signals from the local Recollect memory store —
  the replacement for the retired Cognee insights (B-1368).

  `areas/0` reports per-scope stats in the same shape the tactical UI
  consumed from Cognee (`dataset_id`, `dataset_name`, `item_count`,
  `recent_day_count`, `recent_week_count`, `latest_activity_at`), sourced
  from `recollect_entries` grouped by the scope name in metadata.

  `build/1` turns those stats into insight rows (growth leader, largest
  memory, freshest context, coverage).
  """

  import Ecto.Query

  alias Home.Repo
  alias Recollect.Schema.Entry

  @doc """
  Per-scope activity stats, shaped like the old Cognee dataset stats so
  `Home.ActivityFocus` and the LiveViews need no shape changes.
  """
  def areas do
    day_ago = DateTime.add(DateTime.utc_now(), -86_400, :second)
    week_ago = DateTime.add(DateTime.utc_now(), -7 * 86_400, :second)

    Entry
    |> group_by([e], fragment("metadata->>'scope'"))
    |> select([e], %{
      dataset_id: fragment("metadata->>'scope'"),
      dataset_name: fragment("metadata->>'scope'"),
      item_count: count(e.id),
      recent_day_count: filter(count(e.id), e.inserted_at > ^day_ago),
      recent_week_count: filter(count(e.id), e.inserted_at > ^week_ago),
      latest_activity_at: max(e.inserted_at)
    })
    |> Repo.all()
  end

  @doc "Tactical insight rows derived from `areas/0` stats."
  def build([]), do: []

  def build(stats) do
    [
      growth_insight(stats),
      largest_insight(stats),
      activity_insight(stats),
      coverage_insight(stats)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp growth_insight(stats) do
    leader =
      Enum.max_by(stats, &{&1.recent_day_count, &1.recent_week_count}, fn -> nil end)

    cond do
      is_nil(leader) ->
        nil

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
      "#{largest.item_count} records, #{percent(largest.item_count, total_items(stats))}% of all indexed Recollect material.",
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
    insight(
      "coverage",
      "Memory coverage",
      "#{length(stats)} knowledge areas hold #{total_items(stats)} indexed records across Recollect.",
      3
    )
  end

  defp insight(signal, title, notes, priority) do
    %{
      id: "recollect-#{signal}",
      signal: signal,
      title: title,
      notes: notes,
      priority: priority,
      source: "recollect"
    }
  end

  defp total_items(stats), do: Enum.sum(Enum.map(stats, & &1.item_count))
  defp percent(_part, 0), do: 0
  defp percent(part, total), do: round(part / total * 100)

  defp display_name(name) do
    name
    |> String.replace(~r/[-_]+/, " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
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
