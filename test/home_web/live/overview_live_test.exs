defmodule HomeWeb.OverviewLiveTest do
  use HomeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "renders the tactical status surfaces", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#overview-vitals")
    assert has_element?(view, "#current-focus")
    assert has_element?(view, "#upcoming-meetings")
    assert has_element?(view, "#personal-goals")
    assert has_element?(view, "#cognee-insights")
  end

  test "creates and completes a personal goal", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#add-goal") |> render_click()

    view
    |> form("#goal-form", goal: %{title: "Ship tactical overview", priority: 1})
    |> render_submit()

    [goal] = Home.Tactical.list_goals()
    assert has_element?(view, "#goals-#{goal.id}")

    view |> element("#toggle-goal-#{goal.id}") |> render_click()
    assert Home.Repo.get!(Home.Tactical.Item, goal.id).status == "completed"
  end

  test "adds an upcoming meeting", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#add-meeting") |> render_click()

    view
    |> form("#meeting-form",
      meeting: %{title: "Weekly review", starts_at: "2027-01-02T10:00", notes: "Studio"}
    )
    |> render_submit()

    assert has_element?(view, "#meeting-stream article")
  end
end
