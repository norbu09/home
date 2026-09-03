defmodule HomeWeb.MemoryLiveTest do
  use HomeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Home.Settings

  setup do
    Settings.put_bool("memory_import.enabled", false)
    :ok
  end

  test "renders the import switch and run button", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/memory")

    assert has_element?(view, "#memory-import-toggle[role='switch'][aria-checked='false']")
    assert has_element?(view, "#memory-import-now")
    assert has_element?(view, "#memory-no-run")
  end

  test "toggling the switch persists the setting", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/memory")

    view |> element("#memory-import-toggle") |> render_click()
    assert has_element?(view, "#memory-import-toggle[aria-checked='true']")
    assert Settings.get_bool("memory_import.enabled") == true

    view |> element("#memory-import-toggle") |> render_click()
    assert has_element?(view, "#memory-import-toggle[aria-checked='false']")
    assert Settings.get_bool("memory_import.enabled") == false
  end

  test "renders the last run summary when one is recorded", %{conn: conn} do
    Settings.put_json("memory_import.last_run", %{
      "at" => "2026-09-03T12:00:00Z",
      "results" => %{
        "claude" => %{
          "fetched" => 10,
          "stored" => 8,
          "skipped" => 2,
          "by_project" => %{"home" => 8}
        }
      }
    })

    {:ok, view, _html} = live(conn, ~p"/memory")

    assert has_element?(view, "#memory-last-run-at")
    assert has_element?(view, "#memory-run-claude")
  end
end
