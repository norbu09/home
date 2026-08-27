defmodule HomeWeb.OverviewLive do
  @moduledoc "Personal tactical status overview."
  use HomeWeb, :live_view

  alias Home.LLMProxy.UsageTracker
  alias Home.Secrets.Store
  alias Home.Tactical

  on_mount {HomeWeb.LiveUserAuth, :live_user_optional}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Home.PubSub, "llm_usage")

    {:ok,
     socket
     |> assign(:page_title, "Overview")
     |> assign_new(:current_scope, fn -> nil end)
     |> assign(:goal_form, goal_form())
     |> assign(:meeting_form, meeting_form())
     |> assign(:show_goal_form, false)
     |> assign(:show_meeting_form, false)
     |> load_overview()}
  end

  @impl true
  def handle_info(:llm_usage_updated, socket), do: {:noreply, load_focus(socket)}

  @impl true
  def handle_event("toggle_form", %{"kind" => "goal"}, socket) do
    {:noreply, assign(socket, :show_goal_form, !socket.assigns.show_goal_form)}
  end

  def handle_event("toggle_form", %{"kind" => "meeting"}, socket) do
    {:noreply, assign(socket, :show_meeting_form, !socket.assigns.show_meeting_form)}
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

  def handle_event("save_meeting", %{"meeting" => params}, socket) do
    attrs =
      Map.merge(params, %{
        "kind" => "meeting",
        "status" => "active",
        "source" => "manual",
        "priority" => 2
      })

    case Tactical.create_item(attrs) do
      {:ok, _item} ->
        {:noreply,
         socket
         |> assign(:meeting_form, meeting_form())
         |> assign(:show_meeting_form, false)
         |> load_tactical_items()}

      {:error, changeset} ->
        {:noreply, assign(socket, :meeting_form, to_form(changeset, as: :meeting))}
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

  defp load_overview(socket) do
    socket
    |> assign(:secret_count, length(Store.list_all()))
    |> assign(:today, Date.utc_today())
    |> load_focus()
    |> load_tactical_items()
  end

  defp load_focus(socket) do
    snapshot = UsageTracker.snapshot()

    focuses =
      snapshot.projects
      |> Enum.filter(&(&1.calls > 0))
      |> Enum.take(4)
      |> Enum.map(fn project ->
        %{
          id: project.id,
          name: project.name,
          calls: project.calls,
          tokens: project.input_tokens + project.output_tokens,
          cost: project.cost_usd,
          last_seen_at: project.last_seen_at
        }
      end)

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
    meetings = Tactical.list_upcoming_meetings()
    insights = Tactical.list_insights()

    socket
    |> assign(:goals_empty?, goals == [])
    |> assign(:meetings_empty?, meetings == [])
    |> assign(:insights_empty?, insights == [])
    |> assign(:goal_progress, goal_progress(goals))
    |> stream(:goals, goals, reset: true)
    |> stream(:meetings, meetings, reset: true)
    |> stream(:insights, insights, reset: true)
  end

  defp goal_form do
    to_form(%{"title" => "", "notes" => "", "due_on" => "", "priority" => 2}, as: :goal)
  end

  defp meeting_form do
    to_form(%{"title" => "", "notes" => "", "starts_at" => ""}, as: :meeting)
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
  defp timestamp(nil), do: "NO RECENT ACTIVITY"
  defp timestamp(value), do: Calendar.strftime(value, "%H:%MZ")
  defp meeting_time(nil), do: "TIME PENDING"
  defp meeting_time(value), do: Calendar.strftime(value, "%a %d %b · %H:%MZ")
  defp due_date(nil), do: "NO DEADLINE"
  defp due_date(value), do: Calendar.strftime(value, "%d %b")
end
