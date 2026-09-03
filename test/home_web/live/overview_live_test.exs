defmodule HomeWeb.OverviewLiveTest do
  use HomeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "renders the tactical status surfaces", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#overview-vitals")
    assert has_element?(view, "#home-sidebar img[src='/images/home-core-mark.png']")
    assert has_element?(view, "#overview-local-clock[data-timezone='Europe/Lisbon'] time")
    assert has_element?(view, "#overview-local-clock[phx-hook='LocalClock']")
    assert has_element?(view, "#current-focus")
    assert has_element?(view, "#commit-history")
    assert has_element?(view, "#refresh-git-activity")
    assert has_element?(view, "#personal-goals")
    assert has_element?(view, "#memory-insights")
    assert has_element?(view, "#refresh-memory-insights")
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

  test "links active workstreams to project intelligence", %{conn: conn} do
    Home.LLMProxy.UsageTracker.reset()

    :ok =
      Home.LLMProxy.UsageTracker.record(%{
        project: "ops_center",
        provider: :openrouter,
        model: "z-ai/glm-5.2",
        input_tokens: 20,
        output_tokens: 5,
        latency_ms: 100
      })

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#focus-stream a[href='/router/projects/ops_center']")
  end
end
