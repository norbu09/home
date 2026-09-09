defmodule Home.Brief.Backend.AgenticTest do
  use Home.DataCase, async: false

  alias Home.Brief
  alias Home.Brief.Backend.Agentic

  defmodule FakeRunner do
    @moduledoc false
    def run(_opts), do: {:ok, %{text: "## Summary\nSwept the fleet.\n\n- [ ] follow up on meili"}}
  end

  defp with_fake_runner(module, fun) do
    old = Application.get_env(:home, :agentic_backend, [])

    Application.put_env(
      :home,
      :agentic_backend,
      Keyword.merge(old,
        run_callback: &module.run/1,
        force_available: true
      )
    )

    try do
      fun.()
    after
      Application.put_env(:home, :agentic_backend, old)
    end
  end

  defp cli_prompt!(backend) do
    Brief.create_prompt!(%{
      name: "Agentic Sweep",
      slug: "agentic-#{backend}",
      category: "infrastructure",
      system_prompt: "Be a ops analyst.",
      user_prompt: "Sweep the fleet today {{date}}.",
      backend: backend
    })
  end

  test "returns a result map for a success path through the injected runner" do
    with_fake_runner(FakeRunner, fn ->
      prompt = cli_prompt!("opencode")
      {:ok, brief} = Brief.create(%{prompt_id: prompt.id, status: "running"})

      assert {:ok, result} = Agentic.run(prompt, brief)
      assert result.content =~ "Swept the fleet."
      assert result.parsed == nil
      assert result.model_used == "opencode"
      assert result.metadata["profile"] == "opencode"
    end)
  end

  test "rejects a backend that is not available (e.g. CLI not on PATH)" do
    old = Application.get_env(:home, :agentic_backend, [])
    Application.put_env(:home, :agentic_backend, force_available: false)

    try do
      prompt = cli_prompt!("codex")
      {:ok, brief} = Brief.create(%{prompt_id: prompt.id, status: "running"})

      assert {:error, "backend \"codex\" unavailable: CLI not found on PATH"} =
               Agentic.run(prompt, brief)
    after
      Application.put_env(:home, :agentic_backend, old)
    end
  end

  test "propagates a runner error" do
    defmodule FailingRunner do
      @moduledoc false
      def run(_opts), do: {:error, :exploded}
    end

    with_fake_runner(FailingRunner, fn ->
      prompt = cli_prompt!("opencode")
      {:ok, brief} = Brief.create(%{prompt_id: prompt.id, status: "running"})

      assert {:error, :exploded} = Agentic.run(prompt, brief)
    end)
  end
end
