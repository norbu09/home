defmodule Home.AgentForge.HTTP do
  @moduledoc """
  Raw HTTP transport for the agent-forge daemon (Req-based).

  Two bearer-authed endpoints, both under the daemon's public origin:

    * `POST /jobs`          — enqueue a job (`202 {job_id, status}`); this is
      the daemon's webhook router (`AgentForge.Web.Router` in kfos_agent).
    * `GET /api/runs/:id`   — one run + its model calls (`200 {run: …}`; the
      run id is `job_<job_id>`); from the dashboard/API router
      (`AgentForgeWeb.ApiController`).

  The bearer token is the same `AGENT_WEBHOOK_TOKEN` that guards job dispatch
  on the daemon (kfos_agent: `AgentForge.Secrets.get("AGENT_WEBHOOK_TOKEN")`),
  delivered to Home via its own secret store or env.
  """

  require Logger

  # Returns {:ok, job_id_text} | {:error, reason}
  def enqueue(product_meta) do
    with {:ok, token} <- Home.AgentForge.Client.token(),
         base <- Home.AgentForge.Client.base_url(),
         payload <- enqueue_payload(product_meta) do
      case Req.post!(base <> "/jobs",
             json: payload,
             headers: [{"authorization", "Bearer " <> token}],
             receive_timeout: Home.AgentForge.Client.receive_timeout()
           ) do
        %{status: status, body: body} when status in 200..299 ->
          case body do
            %{"job_id" => job_id} when is_binary(job_id) -> {:ok, job_id}
            other -> {:error, {:unexpected_enqueue_response, other}}
          end

        %{status: status, body: body} ->
          {:error, {:enqueue_http, status, body}}
      end
    end
  end

  # Returns {:ok, run_map} | {:error, {:run_not_found, …}} | {:error, reason}
  def run_status(job_id) when is_binary(job_id) do
    with {:ok, token} <- Home.AgentForge.Client.token(),
         base <- Home.AgentForge.Client.base_url() do
      case Req.get!(base <> "/api/runs/job_" <> job_id,
             headers: [{"authorization", "Bearer " <> token}],
             receive_timeout: Home.AgentForge.Client.receive_timeout()
           ) do
        %{status: 200, body: %{"run" => run}} when is_map(run) ->
          {:ok, run}

        %{status: 404, body: body} ->
          {:error, {:run_not_found, body}}

        %{status: status, body: body} ->
          {:error, {:run_status_http, status, body}}
      end
    end
  end

  defp enqueue_payload(%{} = meta) do
    base = %{
      "project" => Map.get(meta, :project),
      "goal" => Map.get(meta, :goal),
      "source" => %{
        "platform" => Map.get(meta, :source_platform, "brief"),
        "id" => Map.get(meta, :source_id)
      }
    }

    base
    |> maybe_put("specialty", Map.get(meta, :specialty))
    |> maybe_put("base_ref", Map.get(meta, :base_ref))
    |> maybe_put("max_actions", Map.get(meta, :max_actions))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
