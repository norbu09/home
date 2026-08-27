defmodule HomeWeb.RouterLiveTest do
  use HomeWeb.ConnCase

  import Phoenix.LiveViewTest

  setup do
    Home.LLMProxy.UsageTracker.reset()
    :ok
  end

  test "renders the router command dashboard", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/router")

    assert has_element?(view, "#home-sidebar")
    assert has_element?(view, "#router-metrics")
    assert has_element?(view, "#project-allocation")
    assert has_element?(view, "#tool-activity")
    assert has_element?(view, "#provider-channels")
    assert has_element?(view, "a[href='/router/projects/mark_mesh']")
  end

  test "renders attributed tool activity separately", %{conn: conn} do
    Home.LLMProxy.UsageTracker.record(%{
      project: "tools",
      tool: "cognee",
      provider: :openrouter,
      model: "z-ai/glm-5.2:free",
      input_tokens: 10,
      output_tokens: 5,
      latency_ms: 180
    })

    {:ok, view, _html} = live(conn, ~p"/router")

    assert has_element?(view, "#tools-cognee")
  end

  test "toggles project request access", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/router")

    assert has_element?(view, "#projects-ops_center[data-state='enabled']")

    view
    |> element("#project-toggle-ops_center")
    |> render_click()

    assert has_element?(view, "#projects-ops_center[data-state='disabled']")
  end

  test "updates a project provider route", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/router")

    view
    |> element("#project-route-mark_mesh")
    |> render_click()

    assert has_element?(view, "#routing-policy-form")

    view
    |> form("#routing-policy-form", routing: %{routing_mode: "pinned", provider: "openai"})
    |> render_submit()

    assert has_element?(view, "#project-route-mark_mesh[data-routing='openai']")
  end
end
