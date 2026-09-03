defmodule HomeWeb.MemoryLive do
  @moduledoc """
  Agent memory console: toggle the regular coding-agent memory import and
  trigger manual runs. Backed by `Home.Memory.ImportScheduler` +
  `Home.Memory.Importer`.
  """
  use HomeWeb, :live_view

  alias Home.Memory.{ImportScheduler, Importer}
  alias Home.Secrets.Store

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
  def handle_event("toggle_import", _params, socket) do
    enabled = !socket.assigns.import_enabled
    {:ok, _} = Home.Settings.put_bool("memory_import.enabled", enabled)

    {:noreply, assign(socket, :import_enabled, enabled)}
  end

  def handle_event("import_now", _params, socket) do
    ImportScheduler.import_now()
    {:noreply, assign(socket, :running?, true)}
  end

  @impl true
  def handle_info(:memory_import_started, socket), do: {:noreply, assign(socket, :running?, true)}

  def handle_info({:memory_import_finished, _results}, socket) do
    {:noreply, assign_state(socket)}
  end

  def handle_info(:memory_import_failed, socket) do
    {:noreply,
     socket
     |> assign(:running?, false)
     |> put_flash(:error, "Memory import failed — check the logs")}
  end

  defp format_at(nil), do: "—"

  defp format_at(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
      _ -> iso
    end
  end

  defp assign_state(socket) do
    status =
      try do
        ImportScheduler.status()
      catch
        :exit, _ -> %{running?: false, last_run_at: nil}
      end

    socket
    |> assign(:active_nav, :memory)
    |> assign(:import_enabled, ImportScheduler.enabled?())
    |> assign(:running?, Map.get(status, :running?, false))
    |> assign(:last_run, Importer.last_run())
  end
end
