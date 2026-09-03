defmodule HomeWeb.OverviewLive do
  @moduledoc "Personal tactical status overview."
  use HomeWeb, :live_view

  alias Home.{ActivityFocus, GitActivity}
  alias Home.LLMProxy.UsageTracker
  alias Home.Memory.Insights
  alias Home.Secrets.Store
  alias Home.Tactical

  on_mount {HomeWeb.LiveUserAuth, :live_user_optional}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Home.PubSub, "llm_usage")
      Phoenix.PubSub.subscribe(Home.PubSub, Home.Memory.ImportScheduler.topic())
    end

    {:ok,
     socket
     |> assign(:page_title, "Overview")
     |> assign_new(:current_scope, fn -> nil end)
     |> assign(:goal_form, goal_form())
     |> assign(:show_goal_form, false)
     |> load_overview()}
  end

  @impl true
  def handle_info(:llm_usage_updated, socket), do: {:noreply, load_focus(socket)}

  def handle_info({:memory_import_finished, _results}, socket) do
    {:noreply, socket |> load_insights() |> load_focus()}
  end

  def handle_info(:memory_import_started, socket) do
    {:noreply, assign(socket, :memory_status, :syncing)}
  end

  @impl true
  def handle_event("toggle_form", %{"kind" => "goal"}, socket) do
    {:noreply, assign(socket, :show_goal_form, !socket.assigns.show_goal_form)}
  end

  def handle_event("save_goal", %{"goal" => params}, socket) do
    attrs = Map.merge(params, %{"kind" => "goal", "status" => "active", "source" => "manual"})

    case Tactical.create_item(attrs) do
      {:ok, _item} ->
        {:noreply,
         socket
         |> assign(:goal_form, goal_form())
         |> assign(:show_goal_form, false)
         |> load_tactical_items()}

      {:error, changeset} ->
        {:noreply, assign(socket, :goal_form, to_form(changeset, as: :goal))}
    end
  end

  def handle_event("toggle_goal", %{"id" => id}, socket) do
    _ = Tactical.toggle_goal(id)
    {:noreply, load_tactical_items(socket)}
  end

  def handle_event("dismiss_item", %{"id" => id}, socket) do
    _ = Tactical.dismiss(id)
    {:noreply, load_tactical_items(socket)}
  end

  def handle_event("refresh_memory_insights", _params, socket) do
    {:noreply, load_insights(socket)}
  end

  def handle_event("refresh_git_activity", _params, socket) do
    {:noreply, socket |> load_git_activity() |> load_focus()}
  end

  defp load_overview(socket) do
    socket
    |> assign(:secret_count, length(Store.list_all()))
    |> assign(:today, Date.utc_today())
    |> load_git_activity()
    |> load_focus()
    |> load_tactical_items()
  end

  defp load_focus(socket) do
    snapshot = UsageTracker.snapshot()

    focuses =
      ActivityFocus.build(snapshot.projects, socket.assigns.git_projects, memory_areas())

    socket
    |> assign(:snapshot, snapshot)
    |> assign(:focuses_empty?, focuses == [])
    |> assign(:active_projects, length(focuses))
    |> assign(:today_calls, snapshot.today.calls)
    |> assign(:today_tokens, compact(snapshot.today.input_tokens + snapshot.today.output_tokens))
    |> assign(:month_cost, money(snapshot.month.cost_usd))
    |> stream(:focuses, focuses, reset: true)
  end

  defp load_tactical_items(socket) do
    goals = Tactical.list_goals()

    socket
    |> assign(:goals_empty?, goals == [])
    |> assign(:goal_progress, goal_progress(goals))
    |> stream(:goals, goals, reset: true)
    |> load_insights()
  end

  defp load_git_activity(socket) do
    projects = GitActivity.recent()

    socket
    |> assign(:git_projects, projects)
    |> assign(:git_projects_empty?, projects == [])
    |> assign(:git_commit_count, Enum.sum(Enum.map(projects, & &1.commit_count)))
    |> stream(:git_projects_stream, projects, reset: true)
  end

  defp load_insights(socket) do
    areas = memory_areas()
    insights = Insights.build(areas) ++ Tactical.list_insights()

    socket
    |> assign(:insights_empty?, insights == [])
    |> assign(:memory_status, memory_status(areas))
    |> assign(:memory_scope_count, length(areas))
    |> stream(:insights, insights, reset: true)
  end

  # Scopes that hold any entries — cached per render; the query is a cheap
  # aggregate over recollect_entries.
  defp memory_areas, do: Insights.areas()

  defp goal_form do
    to_form(%{"title" => "", "notes" => "", "due_on" => "", "priority" => 2}, as: :goal)
  end

  defp goal_progress([]), do: 0

  defp goal_progress(goals) do
    round(Enum.count(goals, &(&1.status == "completed")) / length(goals) * 100)
  end

  defp compact(value) when value >= 1_000_000,
    do: :erlang.float_to_binary(value / 1_000_000, decimals: 1) <> "M"

  defp compact(value) when value >= 1_000,
    do: :erlang.float_to_binary(value / 1_000, decimals: 1) <> "K"

  defp compact(value), do: Integer.to_string(value)
  defp money(value), do: "$" <> :erlang.float_to_binary(value * 1.0, decimals: 2)
  defp due_date(nil), do: "NO DEADLINE"
  defp due_date(value), do: Calendar.strftime(value, "%d %b")
  defp insight_badge(%{source: "recollect", signal: signal}), do: String.upcase(signal)
  defp insight_badge(insight), do: "P#{insight.priority}"

  defp memory_status([]), do: :idle
  defp memory_status(_areas), do: :ready

  defp memory_status_label(:ready, count), do: "#{count} SCOPES TRACKED"
  defp memory_status_label(:syncing, _count), do: "IMPORTING"
  defp memory_status_label(_, _count), do: "AWAITING SIGNAL"

  defp focus_summary(focus) do
    [
      focus.router_calls > 0 && count_label(focus.router_calls, "LLM call"),
      focus.commits > 0 && count_label(focus.commits, "commit"),
      focus.memory_activity > 0 && count_label(focus.memory_activity, "memory update")
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  defp count_label(1, label), do: "1 #{label}"
  defp count_label(count, label), do: "#{count} #{label}s"

  defp signal_label(1), do: "1 SIGNAL"
  defp signal_label(count), do: "#{count} SIGNALS"

  defp relative_timestamp(nil), do: "NO TIMESTAMP"

  defp relative_timestamp(datetime) do
    seconds = max(DateTime.diff(DateTime.utc_now(), datetime, :second), 0)

    cond do
      seconds < 60 -> "NOW"
      seconds < 3_600 -> "#{div(seconds, 60)}M AGO"
      seconds < 86_400 -> "#{div(seconds, 3_600)}H AGO"
      true -> "#{div(seconds, 86_400)}D AGO"
    end
  end
end
