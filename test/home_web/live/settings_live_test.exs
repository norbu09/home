defmodule HomeWeb.SettingsLiveTest do
  use HomeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Home.Settings

  setup do
    Settings.put_bool("memory_import.enabled", false)
    :ok
  end

  test "renders the automation switches", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#settings-automation")

    assert has_element?(
             view,
             "#settings-memory-import-toggle[role='switch'][aria-checked='false']"
           )
  end

  test "toggling the memory import switch persists the setting", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view |> element("#settings-memory-import-toggle") |> render_click()
    assert has_element?(view, "#settings-memory-import-toggle[aria-checked='true']")
    assert Settings.get_bool("memory_import.enabled") == true
  end

  test "renders the daily brief switch and status", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#settings-brief")
    assert has_element?(view, "#settings-brief-toggle[role='switch'][aria-checked='false']")
    assert has_element?(view, "#settings-brief-run-now")
  end

  test "toggling the brief scheduler switch persists the setting", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view |> element("#settings-brief-toggle") |> render_click()
    assert has_element?(view, "#settings-brief-toggle[aria-checked='true']")
    assert Settings.get_bool("brief_scheduler.enabled") == true
  end
end
