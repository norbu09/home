defmodule HomeWeb.SettingsLive do
  @moduledoc """
  App-wide settings: the Home.Settings-backed switches that gate scheduled
  automation. Detail consoles (e.g. memory import runs) live on their own
  pages; this page is the switchboard.
  """
  use HomeWeb, :live_view

  alias Home.Memory.ImportScheduler
  alias Home.Secrets.Store
  alias Home.Settings

  on_mount {HomeWeb.LiveUserAuth, :live_user_optional}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Home.PubSub, ImportScheduler.topic())
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

  @impl true
  def handle_info({:memory_import_finished, _results}, socket),
    do: {:noreply, assign_state(socket)}

  def handle_info(:memory_import_started, socket), do: {:noreply, assign(socket, :running?, true)}
  def handle_info(:memory_import_failed, socket), do: {:noreply, assign(socket, :running?, false)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp assign_state(socket) do
    status =
      try do
        ImportScheduler.status()
      catch
        :exit, _ -> %{running?: false}
      end

    socket
    |> assign(:active_nav, :settings)
    |> assign(:memory_import_enabled, Settings.get_bool("memory_import.enabled", false))
    |> assign(:running?, Map.get(status, :running?, false))
  end
end
