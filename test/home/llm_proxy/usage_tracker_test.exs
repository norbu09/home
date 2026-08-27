defmodule Home.LLMProxy.UsageTrackerTest do
  use Home.DataCase, async: false

  alias Home.LLMProxy.UsageTracker
  alias Home.LLMProxy.UsageLog

  setup do
    UsageTracker.reset()
    :ok
  end

  test "aggregates provider-reported cost by project and provider" do
    assert :ok =
             UsageTracker.record(%{
               project: "ops_center",
               provider: :openrouter,
               model: "openrouter/auto",
               input_tokens: 120,
               output_tokens: 30,
               cost_usd: 0.0125,
               latency_ms: 240
             })

    snapshot = UsageTracker.snapshot()
    project = Enum.find(snapshot.projects, &(&1.id == "ops_center"))
    provider = Enum.find(snapshot.providers, &(&1.provider == "openrouter"))

    assert project.calls == 1
    assert project.input_tokens == 120
    assert_in_delta project.cost_usd, 0.0125, 0.000001
    assert provider.latency_ms == 240
  end

  test "estimates cost locally when a provider does not report it" do
    assert :ok =
             UsageTracker.record(%{
               project: "mark_mesh",
               provider: :zai,
               model: "glm-5.2",
               input_tokens: 1_000_000,
               output_tokens: 1_000_000
             })

    snapshot = UsageTracker.snapshot()
    project = Enum.find(snapshot.projects, &(&1.id == "mark_mesh"))

    assert_in_delta project.cost_usd, 2.80, 0.000001
  end

  test "flushes ETS deltas to append-only history without changing the snapshot" do
    assert :ok =
             UsageTracker.record(%{
               project: "ops_center",
               provider: :openrouter,
               model: "openrouter/auto",
               input_tokens: 42,
               output_tokens: 8,
               cost_usd: 0.003,
               latency_ms: 120
             })

    assert {:ok, 1} = UsageTracker.flush()
    assert [%UsageLog{} = log] = Repo.all(UsageLog)
    assert log.project == "ops_center"
    assert log.input_tokens == 42
    assert log.output_tokens == 8

    project = Enum.find(UsageTracker.snapshot().projects, &(&1.id == "ops_center"))
    assert project.calls == 1
    assert_in_delta project.cost_usd, 0.003, 0.000001
    assert {:ok, 0} = UsageTracker.flush()
  end

  test "tracks tool usage as a separate aggregate dimension" do
    assert :ok =
             UsageTracker.record(%{
               project: "tools",
               tool: "cognee",
               provider: :openrouter,
               model: "z-ai/glm-5.2:free",
               input_tokens: 10,
               output_tokens: 5,
               latency_ms: 180
             })

    snapshot = UsageTracker.snapshot()
    tool = Enum.find(snapshot.tools, &(&1.id == "cognee"))
    project = Enum.find(snapshot.projects, &(&1.id == "tools"))

    assert tool.calls == 1
    assert tool.input_tokens == 10
    assert tool.output_tokens == 5
    assert tool.provider_count == 1
    assert tool.latency_ms == 180
    assert project.calls == 1
  end

  test "includes configured tools in the tools project before their first call" do
    details = UsageTracker.project_details("tools")

    assert %{calls: 0, models: [], provider_count: 0} =
             Enum.find(details.tools, &(&1.id == "cognee"))
  end

  test "applies a project default model only to chat routes" do
    assert {:ok, _policy} =
             UsageTracker.set_project_policy("ops_center", %{
               default_model: "openrouter/openai/gpt-4o"
             })

    original = [{:zai, "glm-5.2"}]

    assert [{:openrouter, "openai/gpt-4o"}] =
             UsageTracker.apply_project_policy(original, "ops_center", :chat)

    assert original == UsageTracker.apply_project_policy(original, "ops_center", :embedding)
  end
end
