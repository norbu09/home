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

  test "renders the forge connection panel with editable config", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#settings-forge")
    assert has_element?(view, "#settings-forge-toggle[role='switch']")
    assert has_element?(view, "#agent_forge_base_url")
    assert has_element?(view, "#agent_forge_project")
    assert has_element?(view, "#agent_forge_specialty")
    assert has_element?(view, "#agent_forge_token")
    assert has_element?(view, "#settings-forge-token-save")
  end

  test "toggling the forge switch persists the setting", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view |> element("#settings-forge-toggle") |> render_click()
    assert has_element?(view, "#settings-forge-toggle[aria-checked='false']")
    assert Settings.get_bool("agent_forge.enabled") == false
  end

  test "saving forge connection persists base URL, project, and specialty", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#settings-forge-config", %{
      config: %{
        base_url: "https://forge.example.nz",
        project: "mark_mesh",
        specialty: "research"
      }
    })
    |> render_submit()

    assert Settings.get("agent_forge.base_url") == "https://forge.example.nz"
    assert Settings.get("agent_forge.project") == "mark_mesh"
    assert Settings.get("agent_forge.specialty") == "research"
  end

  test "storing the bearer token writes it to the vault", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#settings-forge-token", %{token: %{value: "secret-token"}})
    |> render_submit()

    assert Home.AgentForge.Client.token() == {:ok, "secret-token"}
    assert has_element?(view, "#settings-forge-token-status")
    assert render(view) =~ "TOKEN STORED"
  end
end
