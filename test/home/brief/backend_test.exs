defmodule Home.Brief.BackendTest do
  use Home.DataCase, async: false

  alias Home.Brief.Backend
  alias Home.Brief.Backend.Agentic

  describe "impl/1" do
    test "maps each backend id to an implementation" do
      assert {:ok, Home.Brief.Backend.LLM} = Backend.impl("llm")
      assert {:ok, Home.Brief.Backend.AgentForge} = Backend.impl("agent_forge")
      assert {:ok, Home.Brief.Backend.Agentic} = Backend.impl("opencode")
      assert {:ok, Home.Brief.Backend.Agentic} = Backend.impl("claude_code")
      assert {:ok, Home.Brief.Backend.Agentic} = Backend.impl("codex")
    end

    test "rejects unknown backends" do
      assert {:error, _} = Backend.impl("spacelytics")
    end
  end

  describe "available?/1" do
    test "the llm backend is always available" do
      assert Backend.available?("llm")
    end

    test "agent_forge requires the token and the enabled setting" do
      old_forge = Application.get_env(:home, :agent_forge, [])
      Application.put_env(:home, :agent_forge, Keyword.merge(old_forge, enabled: true))
      System.put_env("AGENT_FORGE_WEBHOOK_TOKEN", "tok")

      try do
        assert Backend.available?("agent_forge")
      after
        Application.put_env(:home, :agent_forge, old_forge)
        System.delete_env("AGENT_FORGE_WEBHOOK_TOKEN")
      end
    end

    test "agentic backends require the CLI binary" do
      for backend <- ["opencode", "claude_code", "codex"] do
        assert Backend.available?(backend) ==
                 (System.find_executable(Agentic.binary(backend)) != nil)
      end
    end

    test "unknown backends are not available" do
      refute Backend.available?("spacelytics")
    end
  end
end
