defmodule HomeWeb.IntelLiveTest do
  use HomeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "renders every operational intelligence route", %{conn: conn} do
    for {path, selector} <- [
          {~p"/services", "#service-registry"},
          {~p"/providers", "#provider-registry"},
          {~p"/requests", "#request-registry"},
          {~p"/policies", "#policy-registry"}
        ] do
      {:ok, view, _html} = live(conn, path)
      assert has_element?(view, selector)
    end
  end

  test "policy controls update request access", %{conn: conn} do
    Home.LLMProxy.UsageTracker.reset()
    {:ok, view, _html} = live(conn, ~p"/policies")

    assert has_element?(view, "#policy-toggle-ops_center")
    assert Home.LLMProxy.UsageTracker.project_allowed?("ops_center")
    view |> element("#policy-toggle-ops_center") |> render_click()
    refute Home.LLMProxy.UsageTracker.project_allowed?("ops_center")
  end
end
