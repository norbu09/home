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
end
