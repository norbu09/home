defmodule Home.Brief.Backend.AgentForge do
  @moduledoc """
  Remote agent backend: hands a brief to the agent-forge daemon (the ops_center
  coder agent with the ops-center MCP fleet tools) and polls until terminal.

  One enqueue + a bounded poll — non-agentic from Home's perspective. The
  agent's report becomes the brief outcome.
  """

  alias Home.AgentForge.Client
  alias Home.Brief.{Conversation, Prompt, Runner}

  import Home.AgentForge.Client, only: [enabled?: 0]

  def available?(_backend) do
    enabled?() and match?({:ok, _}, Client.token())
  end

  def run(%Prompt{} = prompt, %Conversation{} = _brief) do
    with {:ok, %{report: report, run: run}} <- dispatch(prompt),
         {:ok, parsed} <- Runner.parse_response(report) do
      {:ok,
       %{
         content: report,
         parsed: parsed,
         model_used: "agent_forge",
         cost_usd: 0.0,
         metadata: %{
           "dispatch" => "agent_forge",
           "job_id" => run["run_id"],
           "branch" => run["branch"]
         }
       }}
    end
  end

  defp dispatch(prompt) do
    Client.fleet_sweep_report(
      goal: prompt.user_prompt || "Run a fleet-status sweep.",
      source_id: "brief:#{prompt.slug}",
      max_actions: 120
    )
  end
end
