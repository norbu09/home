defmodule Home.Brief.Backend do
  @moduledoc """
  Dispatches a brief's execution to the backend configured on its prompt.

  Each prompt carries a `backend` — `llm` (the local proxy, default),
  `agent_forge` (the remote ops_center agent daemon), or a local agentic
  CLI backend (`opencode`, `claude_code`, `codex`). The runner resolves the
  backend and delegates; a backend returns `{:ok, %{...}}` or
  `{:error, reason}` with everything it needs to persist the outcome.
  """

  alias Home.Brief.Backend.{AgentForge, Agentic, LLM}
  alias Home.Brief.{Conversation, Prompt}

  @doc "Resolve and run the brief through its configured backend."
  def run(%Prompt{} = prompt, %Conversation{} = brief) do
    case impl(prompt.backend) do
      {:ok, module} -> module.run(prompt, brief)
      {:error, reason} -> {:error, {:backend_unavailable, reason}}
    end
  end

  @doc "The implementation module for a backend name, or `{:error, reason}`."
  def impl(backend) when backend in ~w(llm agent_forge opencode claude_code codex) do
    {:ok, module_for(backend)}
  end

  def impl(other) do
    {:error, "unknown backend: #{inspect(other)}"}
  end

  @doc "True when the backend's execution machinery is available on this host."
  def available?(backend) when backend in ~w(llm agent_forge opencode claude_code codex) do
    module_for(backend).available?(backend)
  end

  def available?(_other), do: false

  defp module_for("llm"), do: LLM
  defp module_for("agent_forge"), do: AgentForge
  defp module_for("opencode"), do: Agentic
  defp module_for("claude_code"), do: Agentic
  defp module_for("codex"), do: Agentic
end
