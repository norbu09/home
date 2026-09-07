defmodule HomeWeb.SettingsLive do
  @moduledoc """
  App-wide settings: the Home.Settings-backed switches that gate scheduled
  automation. Detail consoles (e.g. memory import runs) live on their own
  pages; this page is the switchboard.
  """
  use HomeWeb, :live_view

  alias Home.Brief
  alias Home.Brief.Scheduler
  alias Home.Memory.ImportScheduler
  alias Home.Secrets.Store
  alias Home.Settings
  alias Home.AgentForge.Client

  on_mount {HomeWeb.LiveUserAuth, :live_user_optional}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Home.PubSub, ImportScheduler.topic())
      Phoenix.PubSub.subscribe(Home.PubSub, Brief.topic())
    end

    {:ok,
     socket
     |> assign_new(:current_scope, fn -> nil end)
     |> assign(:secret_count, length(Store.list_all()))
     |> assign_state()}
  end

  @impl true
  def handle_event("toggle_memory_import", _params, socket) do
    enabled = !socket.assigns.memory_import_enabled
    {:ok, _} = Settings.put_bool("memory_import.enabled", enabled)

    {:noreply, assign(socket, :memory_import_enabled, enabled)}
  end

  def handle_event("toggle_brief_scheduler", _params, socket) do
    enabled = !socket.assigns.brief_enabled
    {:ok, _} = Settings.put_bool("brief_scheduler.enabled", enabled)
    {:noreply, assign(socket, :brief_enabled, enabled)}
  end

  def handle_event("brief_run_now", _params, socket) do
    _ = Scheduler.fire_now()
    {:noreply, socket}
  end

  def handle_event("toggle_agent_forge", _params, socket) do
    enabled = !socket.assigns.agent_forge_enabled
    {:ok, _} = Settings.put_bool("agent_forge.enabled", enabled)
    {:noreply, assign(socket, :agent_forge_enabled, enabled)}
  end

  def handle_event("save_agent_forge_config", %{"config" => params}, socket) do
    with {:ok, _} <- Settings.put("agent_forge.base_url", String.trim(params["base_url"] || "")),
         {:ok, _} <- Settings.put("agent_forge.project", String.trim(params["project"] || "")),
         {:ok, _} <- Settings.put("agent_forge.specialty", String.trim(params["specialty"] || "")) do
      {:noreply, put_flash(socket, :info, "Forge connection updated")}
    else
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to update Forge connection")}
    end
  end

  def handle_event("save_agent_forge_token", %{"token" => params}, socket) do
    value = String.trim(params["value"] || "")

    if value == "" do
      {:noreply, put_flash(socket, :error, "Token value is required")}
    else
      case Store.put("agent_forge", "webhook_token", value,
             description: "Forge webhook bearer token"
           ) do
        {:ok, _secret} ->
          {:noreply,
           socket
           |> assign(:agent_forge_token_present?, true)
           |> put_flash(:info, "Token stored // encrypted at rest")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to store token")}
      end
    end
  end

  @impl true
  def handle_info({:memory_import_finished, _results}, socket),
    do: {:noreply, assign_state(socket)}

  def handle_info(:memory_import_started, socket), do: {:noreply, assign(socket, :running?, true)}
  def handle_info(:memory_import_failed, socket), do: {:noreply, assign(socket, :running?, false)}

  def handle_info({:briefs_updated, _kind, _brief}, socket), do: {:noreply, assign_state(socket)}
  def handle_info({:brief_completed, _brief}, socket), do: {:noreply, assign_state(socket)}
  def handle_info({:brief_failed, _brief, _reason}, socket), do: {:noreply, assign_state(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp money(nil), do: "—"
  defp money(value), do: "$" <> :erlang.float_to_binary(value * 1.0, decimals: 2)

  defp assign_state(socket) do
    status =
      try do
        ImportScheduler.status()
      catch
        :exit, _ -> %{running?: false}
      end

    scheduler =
      try do
        Scheduler.status()
      catch
        :exit, _ -> %{running?: false}
      end

    socket
    |> assign(:active_nav, :settings)
    |> assign(:memory_import_enabled, Settings.get_bool("memory_import.enabled", false))
    |> assign(:running?, Map.get(status, :running?, false))
    |> assign(:brief_enabled, Settings.get_bool("brief_scheduler.enabled", false))
    |> assign(:brief_running?, Map.get(scheduler, :running?, false))
    |> assign(:brief_stats, Brief.stats())
    |> assign(:brief_next_run, Brief.next_run())
    |> assign(:agent_forge_enabled, Settings.get_bool("agent_forge.enabled", Client.enabled?()))
    |> assign(:agent_forge_base_url, Settings.get("agent_forge.base_url", Client.base_url()))
    |> assign(:agent_forge_project, Settings.get("agent_forge.project", Client.project()))
    |> assign(:agent_forge_specialty, Settings.get("agent_forge.specialty", Client.specialty()))
    |> assign(:agent_forge_token_present?, secret_present?("agent_forge", "webhook_token"))
  end

  defp secret_present?(service, key) do
    case Store.list(service) do
      secrets when is_list(secrets) -> Enum.any?(secrets, &(&1.key == key and &1.is_active))
      _ -> false
    end
  end
end
