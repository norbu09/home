defmodule Home.AgentForge.Client do
  @moduledoc """
  Fetches a fleet-status report from the agent-forge daemon for an
  infrastructure brief (the non-agentic dispatch source).

  Flow:

    1. `POST /jobs` (bearer, `AgentForge.Web.Router`) enqueues a fleet-sweep
       goal for the project given in `config :home, :agent_forge` (default
       `ops_center`) — that project's coder agent carries the ops-center MCP
       tools and runs the actual health checks.
    2. Poll `GET /api/runs/job_<job_id>` (`AgentForgeWeb.ApiController`) until
       the run reaches a terminal state (`completed` / `failed` / `cancelled`),
       up to `poll_timeout_ms`.
    3. On `completed`, return the agent's `outcome` — the fleet report.

  The daemon's exact API contract lives in kfos_agent
  (`lib/agent_forge/web/router.ex` and `lib/agent_forge_web/controllers/api_controller.ex`).

  The HTTP layer is deliberately a thin seam (`Home.AgentForge.HTTP`) so the
  dispatch + polling logic is unit-testable without a live daemon.
  """

  require Logger

  @terminal_statuses ~w(completed failed cancelled)

  # Configurable transport seam (defaults to the real Req transport) so the
  # dispatch/polling logic is testable without a live daemon.
  def transport, do: config(:transport, Home.AgentForge.HTTP)

  @doc """
  Run a complete fleet sweep: enqueue + poll, returning the finished report.

  Returns `{:ok, %{report:, run:, job_id:}}` or `{:error, reason}`. Any failure
  (enqueue rejected, run failed/cancelled, or poll timeout) is an `{:error, …}`
  the brief runner records as a failed brief.
  """
  @spec fleet_sweep_report(keyword()) :: {:ok, map()} | {:error, term()}
  def fleet_sweep_report(opts \\ []) do
    goal = Keyword.get(opts, :goal) || default_goal()
    source_id = Keyword.get(opts, :source_id) || default_source_id()

    with :ok <- ensure_configured(),
         {:ok, job_id} <-
           transport().enqueue(%{
             project: project(),
             goal: goal,
             source_id: source_id,
             specialty: specialty(),
             max_actions: opts[:max_actions]
           }),
         {:ok, run} <- wait_for_terminal(job_id) do
      case run["status"] do
        "completed" ->
          {:ok, %{job_id: job_id, report: run["outcome"] || "", run: run}}

        "failed" ->
          {:error, {:run_failed, job_id, run}}

        "cancelled" ->
          {:error, {:run_cancelled, job_id, run}}

        other ->
          {:error, {:unexpected_run_status, other, run}}
      end
    end
  end

  @doc "Poll `job_id` until its run reaches a terminal state."
  @spec wait_for_terminal(binary()) :: {:ok, map()} | {:error, term()}
  def wait_for_terminal(job_id) when is_binary(job_id) do
    deadline = System.monotonic_time(:millisecond) + poll_timeout_ms()
    poll_loop(job_id, deadline)
  end

  defp poll_loop(job_id, deadline) do
    case transport().run_status(job_id) do
      {:ok, run} when is_map(run) ->
        status = run["status"] || ""

        if status in @terminal_statuses do
          {:ok, run}
        else
          maybe_reschedule(job_id, deadline)
        end

      {:error, {:run_not_found, _}} ->
        # Run row not created yet (job queued, worker hasn't started).
        maybe_reschedule(job_id, deadline)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_reschedule(job_id, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, {:poll_timeout, job_id}}
    else
      Process.sleep(poll_interval_ms())
      poll_loop(job_id, deadline)
    end
  end

  @doc "Host + scheme for the daemon's public URL (e.g. https://forge.kfos.nz)."
  def base_url do
    config(:base_url, "https://forge.kfos.nz")
  end

  @doc "True when dispatching to agent-forge is enabled."
  def enabled?, do: config(:enabled, true)

  @doc "Repo slug in the daemon's :repos registry whose agent runs the sweep."
  def project do
    config(:project, "ops_center")
  end

  def specialty do
    config(:specialty, "ops")
  end

  @doc """
  The bearer token for the daemon's /jobs + /api surfaces.

  Precedence: vault secret `agent_forge/webhook_token` first (the Settings
  UI writes it there), then the `AGENT_FORGE_WEBHOOK_TOKEN` / `AGENT_WEBHOOK_TOKEN`
  env vars (local dev / CI).
  """
  def token do
    case Home.Secrets.Store.get("agent_forge", "webhook_token") do
      {:ok, token} when is_binary(token) and token != "" ->
        {:ok, token}

      _ ->
        case System.get_env("AGENT_FORGE_WEBHOOK_TOKEN") || System.get_env("AGENT_WEBHOOK_TOKEN") do
          token when is_binary(token) and token != "" -> {:ok, token}
          _ -> {:error, :missing_token}
        end
    end
  end

  def receive_timeout, do: config(:receive_timeout_ms, 30_000)
  def poll_timeout_ms, do: config(:poll_timeout_ms, 15 * 60 * 1000)
  def poll_interval_ms, do: config(:poll_interval_ms, 30_000)

  defp default_goal do
    """
    Run a comprehensive fleet-status sweep and report findings + next steps.

    Using ONLY the ops-center MCP read tools (and the other MCP/fleet tools
    available to you in the ops_center project), check: active and recent
    alerts, deployment convergence across servers, host storage/disk health,
    Postgres HA topology, meilisearch index state, running VMs, active builds,
    and any relevant VM logs for degraded services. Deliver a concise
    operations brief with: (1) what is healthy, (2) what needs attention today
    (name the alert/service and its severity), and (3) concrete suggested next
    steps. Do NOT make any changes — read-only report.
    """
  end

  defp default_source_id do
    "brief:fleet-sweep:#{Date.to_iso8601(Date.utc_today())}"
  end

  defp ensure_configured do
    enabled = config(:enabled, true)

    cond do
      not enabled ->
        {:error, :disabled}

      match?({:ok, _}, token()) ->
        :ok

      true ->
        {:error, :missing_token}
    end
  end

  defp config(key, default) do
    settings_key = "agent_forge.#{key}"
    value = Home.Settings.get(settings_key)

    case value do
      nil ->
        :home
        |> Application.get_env(:agent_forge, [])
        |> Keyword.get(key, default)

      value when is_boolean(default) ->
        value == "true"

      value when is_integer(default) ->
        case Integer.parse(value) do
          {int, _} -> int
          :error -> default
        end

      value ->
        value
    end
  end
end
