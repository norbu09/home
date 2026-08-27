defmodule HomeWeb.ProjectLiveTest do
  use HomeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Home.LLMProxy.UsageTracker

  setup do
    UsageTracker.reset()

    :ok =
      UsageTracker.record(%{
        project: "mark_mesh",
        tool: "opencode",
        provider: :openrouter,
        model: "z-ai/glm-5.2",
        input_tokens: 1_200,
        output_tokens: 300,
        cost_usd: 0.0042,
        latency_ms: 850
      })

    :ok
  end

  test "shows real project usage breakdowns", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/router/projects/mark_mesh")

    assert has_element?(view, "#project-metrics")
    assert has_element?(view, "#project-usage-timeline")
    assert has_element?(view, "#project-model-breakdown")
    assert has_element?(view, "#project-provider-breakdown")
    assert has_element?(view, "#project-tool-breakdown")
    refute has_element?(view, "#project-models-empty")
  end

  test "updates routing controls and pauses the project", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/router/projects/mark_mesh")

    view
    |> form("#project-controls-form",
      controls: %{
        default_model: "openai/gpt-4o",
        provider: "openai",
        quota_usd: "55.00"
      }
    )
    |> render_submit()

    policy = UsageTracker.policy("mark_mesh")
    assert policy.default_model == "openai/gpt-4o"
    assert policy.provider == "openai"
    assert policy.routing_mode == "pinned"
    assert policy.quota_usd == 55.0

    view |> element("#project-detail-toggle") |> render_click()
    refute UsageTracker.project_allowed?("mark_mesh")
  end

  test "shows a configured tool catalog on the tools project", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/router/projects/tools")

    assert has_element?(view, "#project-tool-stream [id$='cognee']")
    assert has_element?(view, "#project-tool-breakdown", "Routed tool catalog")
    refute has_element?(view, "#project-tools-empty")
  end
end
