defmodule HomeWeb.BriefLiveTest do
  use HomeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Home.Brief
  alias Home.Settings

  setup do
    Settings.put_bool("brief_scheduler.enabled", false)
    :ok
  end

  defp insert_prompt(slug, name \\ "Spec Brief") do
    Brief.create_prompt!(%{
      name: name,
      slug: slug,
      category: "planning",
      system_prompt: "system",
      user_prompt: "user",
      schedule: %{"at" => "08:00"},
      priority: 10
    })
  end

  test "index renders queue header, stats panel, and disabled start button", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/briefs")

    assert has_element?(view, "#briefs-header")
    assert has_element?(view, "#briefs-stats")
    assert has_element?(view, "#briefs-queue")
    assert has_element?(view, "#briefs-start-meeting[disabled]")
    assert view |> element("#briefs-today") |> render() =~ "No briefs yet today"
  end

  test "starting the meeting walks through a completed brief and approves it", %{conn: conn} do
    prompt = insert_prompt("spec-brief-meeting")

    {:ok, brief} =
      Brief.create(%{prompt_id: prompt.id, status: "completed", summary: "S", outcome: "O"})

    {:ok, view, _html} = live(conn, ~p"/briefs")

    refute has_element?(view, "#briefs-start-meeting[disabled]")

    view |> element("#briefs-start-meeting") |> render_click()

    assert has_element?(view, "#meeting-advance")
    assert view |> element("#brief-card-#{brief.id}") |> render() =~ "O"

    view |> element("#meeting-advance") |> render_click()

    assert has_element?(view, "#meeting-end") == false
    assert Brief.get_by_id(brief.id).status == "reviewed"
    assert has_element?(view, "#briefs-start-meeting[disabled]")
  end

  test "skipping a brief advances the meeting without reviewing it", %{conn: conn} do
    prompt = insert_prompt("spec-brief-skip")
    {:ok, brief} = Brief.create(%{prompt_id: prompt.id, status: "completed", summary: "S"})

    {:ok, view, _html} = live(conn, ~p"/briefs")
    view |> element("#briefs-start-meeting") |> render_click()
    view |> element("#meeting-skip") |> render_click()

    assert Brief.get_by_id(brief.id).status == "completed"
  end

  test "detail mode renders the latest brief for the slug", %{conn: conn} do
    prompt = insert_prompt("spec-brief-detail", "Spec Detail")

    {:ok, brief} =
      Brief.create(%{
        prompt_id: prompt.id,
        status: "completed",
        summary: "S",
        outcome: "Detail outcome body"
      })

    {:ok, view, _html} = live(conn, ~p"/briefs/spec-brief-detail")

    assert has_element?(view, "#briefs-detail")
    assert view |> element("#brief-card-#{brief.id}") |> render() =~ "Detail outcome body"
    assert has_element?(view, "#discussion-#{brief.id}")
  end
end
