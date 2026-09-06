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
end
