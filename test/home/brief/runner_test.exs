defmodule Home.Brief.RunnerTest do
  use Home.DataCase, async: false

  alias Home.Brief
  alias Home.Brief.Runner
  alias Home.LLMProxy.{ProviderHealth, UsageTracker}

  setup do
    old_proxy = Application.get_env(:home, :llm_proxy, [])
    old_prices = Application.get_env(:home, :llm_model_prices, %{})

    Application.put_env(:home, :llm_model_prices, %{})

    Application.put_env(:home, :llm_proxy,
      provider_client: Home.LLMProxyTestClient,
      model_groups: %{
        "coder" => [%{provider: :openrouter, model: "free-primary", order: 1}]
      }
    )

    ProviderHealth.reset()
    UsageTracker.reset()

    on_exit(fn ->
      Application.put_env(:home, :llm_proxy, old_proxy)
      Application.put_env(:home, :llm_model_prices, old_prices)
      ProviderHealth.reset()
      UsageTracker.reset()
    end)

    :ok
  end

  defp prompt! do
    Brief.create_prompt!(%{
      name: "Test Brief",
      slug: "runner-test-prompt",
      category: "custom",
      system_prompt: "You are a helpful assistant.",
      user_prompt: "What is today? {{date}}",
      schedule: %{"at" => "08:00"}
    })
  end

  describe "build_messages/2" do
    test "resolves template variables" do
      prompt = prompt!()
      {:ok, brief} = Brief.create(%{prompt_id: prompt.id, status: "running"})

      [system, user] = Runner.build_messages(prompt, brief)
      assert system["role"] == "system"
      assert system["content"] == "You are a helpful assistant."
      assert user["role"] == "user"
      assert user["content"] =~ Date.to_string(Date.utc_today())
      refute user["content"] =~ "{{date}}"
    end
  end

  describe "parse_response/1" do
    test "extracts summary and next steps from structured markdown" do
      content = """
      ## Summary
      The infra sweep found no issues.

      ## Key Findings
      - All services healthy

      ## Next Steps
      - [ ] Watch disk usage
      - [ ] Update backup schedule
      """

      assert {:ok, %{summary: "The infra sweep found no issues.", next_steps: steps}} =
               Runner.parse_response(content)

      assert steps == ["Watch disk usage", "Update backup schedule"]
    end

    test "falls back to first line when no ## Summary heading" do
      assert {:ok, %{summary: "Just a line", next_steps: []}} =
               Runner.parse_response("Just a line\n\nMore text")
    end
  end

  describe "run/2" do
    test "completes a brief on LLM success and stores the assistant message" do
      prompt = prompt!()
      {:ok, brief} = Brief.create(%{prompt_id: prompt.id, status: "running"})

      assert {:ok, completed} = Runner.run(prompt, brief)
      assert completed.status == "completed"
      assert completed.summary == "served by openrouter/free-primary"
      assert %DateTime{} = completed.completed_at
      assert [%{role: "assistant"}] = Brief.get_by_id(completed.id).messages
    end

    test "marks a brief failed with a human-readable reason on LLM error" do
      Application.put_env(:home, :llm_proxy,
        provider_client: Home.LLMProxyTestClient,
        model_groups: %{
          "coder" => [%{provider: :zai, model: "glm-5.2", order: 1}]
        }
      )

      ProviderHealth.reset()

      prompt = prompt!()
      {:ok, brief} = Brief.create(%{prompt_id: prompt.id, status: "running"})

      assert {:error, {failed, "rate limited"}} = Runner.run(prompt, brief)
      assert failed.status == "failed"
      assert failed.error == "rate limited"
    end
  end

  describe "dispatch?/1" do
    test "is false for non-dispatch prompts" do
      refute Runner.dispatch?(prompt!())
    end

    test "is true when the prompt backend is agent_forge" do
      prompt =
        Brief.create_prompt!(%{
          name: "Infra",
          slug: "infra-test",
          category: "infrastructure",
          system_prompt: "s",
          user_prompt: "u",
          backend: "agent_forge"
        })

      assert Runner.dispatch?(prompt)
    end
  end

  describe "run/2 dispatch path" do
    alias Home.Brief.Runner

    defmodule FakeForge do
      @moduledoc false

      def start(outcome) do
        Agent.start_link(fn -> outcome end, name: __MODULE__)
      end

      def stop, do: Agent.stop(__MODULE__)

      def enqueue(_meta), do: {:ok, "job_42"}

      def run_status("job_42") do
        outcome = Agent.get(__MODULE__, & &1)
        {:ok, %{"status" => "completed", "outcome" => outcome, "run_id" => "job_42"}}
      end
    end

    setup do
      old_forge = Application.get_env(:home, :agent_forge, [])

      Application.put_env(:home, :agent_forge,
        transport: FakeForge,
        enabled: true,
        project: "ops_center",
        poll_interval_ms: 10,
        poll_timeout_ms: 500
      )

      System.put_env("AGENT_FORGE_WEBHOOK_TOKEN", "test-token")

      on_exit(fn ->
        Application.put_env(:home, :agent_forge, old_forge)
        System.delete_env("AGENT_FORGE_WEBHOOK_TOKEN")
        if Process.whereis(FakeForge), do: FakeForge.stop()
      end)

      :ok
    end

    defp dispatch_prompt! do
      Brief.create_prompt!(%{
        name: "Fleet Sweep",
        slug: "fleet-sweep-test",
        category: "infrastructure",
        system_prompt: "sweep",
        user_prompt: "Check the fleet.",
        backend: "agent_forge"
      })
    end

    test "stores the agent-forge report as the brief outcome" do
      FakeForge.start("## Summary\nFleet healthy\n\n- [ ] watch server7 meili backlog")

      prompt = dispatch_prompt!()
      {:ok, brief} = Brief.create(%{prompt_id: prompt.id, status: "running"})

      assert {:ok, completed} = Runner.run(prompt, brief)
      assert completed.status == "completed"
      assert completed.model_used == "agent_forge"
      assert completed.summary == "Fleet healthy"
      assert completed.next_steps == ["watch server7 meili backlog"]
      assert completed.metadata["dispatch"] == "agent_forge"
      assert completed.metadata["job_id"] == "job_42"
      assert [%{role: "assistant", content: content}] = Brief.get_by_id(completed.id).messages
      assert content =~ "Fleet healthy"
    end
  end
end
