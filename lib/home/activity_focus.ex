defmodule Home.ActivityFocus do
  @moduledoc "Aggregates router, Git, and Cognee activity into ranked workstreams."

  def build(router_projects, git_projects, cognee_areas) do
    %{}
    |> add_router(router_projects)
    |> add_git(git_projects)
    |> add_cognee(cognee_areas)
    |> Map.values()
    |> Enum.filter(&active?/1)
    |> Enum.map(&finalize/1)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(6)
  end

  defp add_router(focuses, projects) do
    Enum.reduce(projects, focuses, fn project, acc ->
      id = normalize(project.id)

      update(acc, id, project.name, fn focus ->
        %{
          focus
          | router_calls: project.calls,
            tokens: project.input_tokens + project.output_tokens,
            cost: project.cost_usd,
            last_seen_at: latest(focus.last_seen_at, project.last_seen_at)
        }
      end)
    end)
  end

  defp add_git(focuses, projects) do
    Enum.reduce(projects, focuses, fn project, acc ->
      id = normalize(project.id)

      update(acc, id, project.name, fn focus ->
        %{
          focus
          | commits: project.commit_count,
            last_seen_at: latest(focus.last_seen_at, project.latest_at)
        }
      end)
    end)
  end

  defp add_cognee(focuses, areas) do
    Enum.reduce(areas, focuses, fn area, acc ->
      id = area.dataset_name |> String.replace_prefix("ocp-", "") |> normalize()

      memory_activity =
        if(area.recent_day_count > 0, do: area.recent_day_count, else: area.recent_week_count)

      update(acc, id, display_name(area.dataset_name), fn focus ->
        %{
          focus
          | memory_activity: focus.memory_activity + memory_activity,
            memory_total: focus.memory_total + area.item_count,
            last_seen_at: latest(focus.last_seen_at, area.latest_activity_at)
        }
      end)
    end)
  end

  defp update(focuses, id, name, updater) do
    Map.update(focuses, id, updater.(empty_focus(id, name)), updater)
  end

  defp empty_focus(id, name) do
    %{
      id: id,
      name: name,
      router_calls: 0,
      tokens: 0,
      cost: 0.0,
      commits: 0,
      memory_activity: 0,
      memory_total: 0,
      last_seen_at: nil
    }
  end

  defp active?(focus) do
    focus.router_calls > 0 or focus.commits > 0 or focus.memory_activity > 0
  end

  defp finalize(focus) do
    signal_count =
      Enum.count([focus.router_calls, focus.commits, focus.memory_activity], &(&1 > 0))

    score =
      signal_count * 100_000 + min(focus.commits, 50) * 1_000 +
        min(focus.router_calls, 500) * 100 + min(focus.memory_activity, 1_000) * 10

    Map.merge(focus, %{signal_count: signal_count, score: score})
  end

  defp normalize(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp display_name(name) do
    name
    |> String.replace_prefix("ocp-", "")
    |> String.replace(~r/[-_]+/, " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp latest(nil, right), do: right
  defp latest(left, nil), do: left
  defp latest(left, right), do: Enum.max([left, right], DateTime)
end
