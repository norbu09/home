defmodule Home.BriefTest do
  use Home.DataCase, async: false

  alias Home.Brief
  alias Home.Brief.{Conversation, Message, Prompt}

  describe "prompts" do
    test "create_prompt!/1 inserts a prompt and is idempotent on slug" do
      attrs = %{
        name: "Test Prompt",
        slug: "test-prompt",
        category: "planning",
        system_prompt: "system",
        user_prompt: "user {{date}}",
        schedule: %{"at" => "08:00"},
        priority: 5
      }

      assert %Prompt{} = prompt = Brief.create_prompt!(attrs)
      assert prompt.slug == "test-prompt"
      assert prompt.priority == 5
      assert prompt.run_weekends == false
      assert prompt.enabled == true
    end

    test "list_enabled_prompts/0 returns enabled prompts by priority" do
      Brief.create_prompt!(%{
        name: "Low Priority",
        slug: "low-priority",
        schedule: %{"at" => "09:00"},
        system_prompt: "s",
        user_prompt: "u",
        priority: 50
      })

      Brief.create_prompt!(%{
        name: "High Priority",
        slug: "high-priority",
        schedule: %{"at" => "08:00"},
        system_prompt: "s",
        user_prompt: "u",
        priority: 10
      })

      Brief.create_prompt!(%{
        name: "Disabled",
        slug: "disabled-prompt",
        schedule: %{"at" => "10:00"},
        system_prompt: "s",
        user_prompt: "u",
        enabled: false
      })

      slugs = Brief.list_enabled_prompts() |> Enum.map(& &1.slug)
      assert "high-priority" in slugs
      assert "low-priority" in slugs
      refute "disabled-prompt" in slugs
      assert Enum.at(slugs, 0) == "high-priority"
    end
  end

  describe "briefs" do
    setup do
      prompt =
        Brief.create_prompt!(%{
          name: "Daily Calendar",
          slug: "daily-calendar-test",
          category: "calendar",
          system_prompt: "system",
          user_prompt: "user",
          schedule: %{"at" => "08:00"},
          priority: 10
        })

      %{prompt: prompt}
    end

    test "create/1 allocates sequential BRF numbers", %{prompt: prompt} do
      {:ok, first} = Brief.create(%{prompt_id: prompt.id, status: "running"})
      {:ok, second} = Brief.create(%{prompt_id: prompt.id, status: "running"})

      assert first.number =~ ~r/\ABRF-\d{4}\z/
      assert Enum.map([first, second], & &1.number) |> Enum.uniq() |> length() == 2

      assert Regex.run(~r/\ABRF-(\d{4})\z/, second.number, capture: :all_but_first) |> hd() !=
               Regex.run(~r/\ABRF-(\d{4})\z/, first.number, capture: :all_but_first) |> hd()
    end

    test "create/1 defaults status to pending and broadcasts", %{prompt: prompt} do
      Phoenix.PubSub.subscribe(Home.PubSub, "briefs")

      {:ok, brief} = Brief.create(%{prompt_id: prompt.id})
      assert brief.status == "pending"

      assert_receive {:briefs_updated, :created, ^brief}
    end

    test "list_today/0 returns today's briefs sorted by prompt priority", %{prompt: prompt} do
      low =
        Brief.create_prompt!(%{
          name: "Low",
          slug: "low-brief-test",
          system_prompt: "s",
          user_prompt: "u",
          priority: 99
        })

      {:ok, _} = Brief.create(%{prompt_id: low.id})
      {:ok, high} = Brief.create(%{prompt_id: prompt.id})

      briefs = Brief.list_today()
      ids = Enum.map(briefs, & &1.id)
      assert hd(ids) == high.id
    end

    test "review/2 marks reviewed with timestamp and notes", %{prompt: prompt} do
      {:ok, brief} = Brief.create(%{prompt_id: prompt.id})
      {:ok, reviewed} = Brief.review(brief, "discussed next steps")
      assert reviewed.status == "reviewed"
      assert reviewed.review_notes == "discussed next steps"
      assert %DateTime{} = reviewed.reviewed_at
    end

    test "dismiss/1 marks dismissed", %{prompt: prompt} do
      {:ok, brief} = Brief.create(%{prompt_id: prompt.id})
      {:ok, dismissed} = Brief.dismiss(brief)
      assert dismissed.status == "dismissed"
    end

    test "fail/2 stores a human-readable error", %{prompt: prompt} do
      {:ok, brief} = Brief.create(%{prompt_id: prompt.id})
      {:ok, failed} = Brief.fail(brief, {:llm_proxy, 500, "boom"})
      assert failed.status == "failed"
      assert failed.error =~ "boom"
      assert %DateTime{} = failed.completed_at
    end

    test "add_message/3 appends to the brief conversation", %{prompt: prompt} do
      {:ok, brief} = Brief.create(%{prompt_id: prompt.id})
      {:ok, message} = Brief.add_message(brief, "assistant", "hello")
      assert %Message{} = message
      assert message.role == "assistant"

      assert [%Message{content: "hello"}] = Brief.get_by_id(brief.id).messages |> Enum.map(& &1)
    end

    test "last_completed_at/1 returns never before completion", %{prompt: prompt} do
      assert Brief.last_completed_at(prompt.id) == "never"
    end

    test "stats/0 counts today's briefs across statuses", %{prompt: prompt} do
      {:ok, open} = Brief.create(%{prompt_id: prompt.id})
      {:ok, _} = Brief.create(%{prompt_id: prompt.id})
      {:ok, _} = Brief.review(open)

      stats = Brief.stats()
      assert stats.total == 2
      assert stats.open == 1
      assert stats.reviewed == 1
      assert stats.failed == 0
    end

    test "next_run/0 returns the single enabled prompt schedule", %{prompt: _prompt} do
      Brief.create_prompt!(%{
        name: "Solo",
        slug: "solo-next-run",
        schedule: %{"at" => "06:00"},
        system_prompt: "s",
        user_prompt: "u",
        priority: 99
      })

      run = Brief.next_run()
      assert %{at: %Time{} = at, prompt: %Prompt{name: "Solo"}} = run
      assert Calendar.strftime(at, "%H:%M") == "06:00"
      assert is_boolean(run.next_day)
    end

    test "get_by_id/1 preloads prompt and messages", %{prompt: prompt} do
      {:ok, brief} = Brief.create(%{prompt_id: prompt.id})
      assert %Conversation{prompt: %Prompt{id: id}} = Brief.get_by_id(brief.id)
      assert id == prompt.id
    end
  end
end
