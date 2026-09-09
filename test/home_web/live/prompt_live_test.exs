defmodule HomeWeb.PromptLiveTest do
  use HomeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Home.Brief

  defp insert_prompt(attrs) do
    Brief.create_prompt!(
      Map.merge(
        %{
          name: "Infra Sweep",
          slug: "prompt-ui-test",
          category: "infrastructure",
          system_prompt: "You are an ops analyst.",
          user_prompt: "Sweep the fleet {{date}}.",
          schedule: %{"at" => "08:15"},
          priority: 40,
          backend: "agent_forge"
        },
        attrs
      )
    )
  end

  test "index lists prompts with backend badge, schedule, and run count", %{conn: conn} do
    prompt = insert_prompt(%{name: "Infra Sweep"})
    {:ok, _} = Brief.create(%{prompt_id: prompt.id, status: "completed"})

    {:ok, view, _html} = live(conn, ~p"/briefs/prompts")

    assert has_element?(view, "#prompts-header")
    assert has_element?(view, "#prompts-list")
    assert render(view) =~ "Infra Sweep"
    assert render(view) =~ "agent_forge"
    assert render(view) =~ "@08:15"
  end

  test "empty state renders when no prompts exist", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/briefs/prompts")
    assert render(view) =~ "NO PROMPTS YET"
  end

  test "create form saves a new prompt", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/briefs/prompts")

    view |> element("#prompts-new") |> render_click()

    assert has_element?(view, "#prompt-form")

    view
    |> form("#prompt-form", %{})
    |> render_submit(%{
      "prompt" => %{
        "name" => "Nightly Roll",
        "slug" => "nightly-roll",
        "category" => "planning",
        "backend" => "llm",
        "priority" => "30",
        "model" => "",
        "system_prompt" => "You plan.",
        "user_prompt" => "Plan {{date}}.",
        "schedule" => %{"at" => "23:00"},
        "enabled" => "true",
        "run_weekends" => "false"
      }
    })

    assert render(view) =~ "Nightly Roll"
    assert Brief.get_prompt!(prompt_slug!("nightly-roll")).backend == "llm"
  end

  test "edit form pre-fills and updates a prompt", %{conn: conn} do
    prompt = insert_prompt(%{name: "Old Name", backend: "llm"})
    {:ok, view, _html} = live(conn, ~p"/briefs/prompts")

    view |> element("#prompt-edit-#{prompt.id}") |> render_click()

    assert has_element?(view, "#prompt-form")
    assert render(view) =~ "Old Name"

    view
    |> form("#prompt-form", %{})
    |> render_submit(%{
      "prompt" => %{
        "name" => "New Name",
        "slug" => "prompt-ui-test",
        "category" => "infrastructure",
        "backend" => "agent_forge",
        "priority" => "40",
        "model" => "",
        "system_prompt" => "You are an ops analyst.",
        "user_prompt" => "Sweep the fleet {{date}}.",
        "schedule" => %{"at" => "08:15"},
        "enabled" => "true",
        "run_weekends" => "false"
      }
    })

    assert render(view) =~ "New Name"
    assert Brief.get_prompt!(prompt.id).name == "New Name"
  end

  test "toggle_active flips the enabled flag", %{conn: conn} do
    prompt = insert_prompt(%{enabled: true})
    {:ok, view, _html} = live(conn, ~p"/briefs/prompts")

    view |> element("#prompt-toggle-#{prompt.id}") |> render_click()

    refute Brief.get_prompt!(prompt.id).enabled
    assert render(view) =~ "OFF"
  end

  test "delete removes the prompt", %{conn: conn} do
    prompt = insert_prompt(%{name: "Doomed"})
    {:ok, view, _html} = live(conn, ~p"/briefs/prompts")

    view |> element("#prompt-delete-#{prompt.id}") |> render_click()

    refute Brief.get_prompt(prompt.id)
    refute render(view) =~ "Doomed"
  end

  test "run now starts a brief and navigates to the brief detail page", %{conn: conn} do
    prompt = insert_prompt(%{backend: "opencode"})

    Application.put_env(:home, :agentic_backend,
      run_callback: fn _opts -> {:ok, %{text: "manual run ok", cost: 0.0}} end,
      force_available: true
    )

    on_exit(fn -> Application.delete_env(:home, :agentic_backend) end)
    Phoenix.PubSub.subscribe(Home.PubSub, Brief.topic())

    {:ok, view, _html} = live(conn, ~p"/briefs/prompts")
    view |> element("#prompt-run-#{prompt.id}") |> render_click()

    assert_redirect(view, ~p"/briefs/prompt-ui-test")

    assert_receive {:briefs_updated, :updated,
                    %Home.Brief.Conversation{status: "completed", prompt_id: brief_prompt_id}},
                   5_000

    assert brief_prompt_id == prompt.id
  end

  defp prompt_slug!(slug) do
    Brief.list_prompts() |> Enum.find(&(&1.slug == slug)) |> Map.fetch!(:id)
  end
end
