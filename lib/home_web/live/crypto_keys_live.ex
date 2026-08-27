defmodule HomeWeb.CryptoKeysLive do
  @moduledoc "Encrypted secret-store management interface."
  use HomeWeb, :live_view

  alias Home.Secrets.Store

  on_mount {HomeWeb.LiveUserAuth, :live_user_optional}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Crypto Keys")
     |> assign_new(:current_scope, fn -> nil end)
     |> assign(:show_form, false)
     |> assign(:editing_secret, nil)
     |> assign(:secret_form, secret_form())
     |> load_secrets()}
  end

  @impl true
  def handle_event("new_secret", _params, socket) do
    {:noreply,
     assign(socket,
       show_form: true,
       editing_secret: nil,
       secret_form: secret_form()
     )}
  end

  def handle_event("edit_secret", %{"id" => id}, socket) do
    case socket.assigns.secrets_by_id[id] do
      nil ->
        {:noreply, socket}

      secret ->
        {:noreply,
         assign(socket,
           show_form: true,
           editing_secret: secret,
           secret_form:
             secret_form(%{
               "service" => secret.service,
               "key" => secret.key,
               "value" => "",
               "description" => secret.description || ""
             })
         )}
    end
  end

  def handle_event("cancel_secret", _params, socket) do
    {:noreply, assign(socket, show_form: false, editing_secret: nil, secret_form: secret_form())}
  end

  def handle_event("save_secret", %{"secret" => params}, socket) do
    service = String.trim(params["service"] || "")
    key = String.trim(params["key"] || "")
    value = params["value"] || ""
    description = blank_to_nil(params["description"])

    if service != "" && key != "" && value != "" do
      case Store.put(service, key, value, description: description) do
        {:ok, _secret} ->
          {:noreply,
           socket
           |> assign(show_form: false, editing_secret: nil, secret_form: secret_form())
           |> load_secrets()
           |> put_flash(:info, "Crypto key stored // encrypted at rest")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to store crypto key")}
      end
    else
      {:noreply, put_flash(socket, :error, "Service, key, and value are required")}
    end
  end

  def handle_event("toggle_secret", %{"id" => id}, socket) do
    case socket.assigns.secrets_by_id[id] do
      nil ->
        {:noreply, socket}

      secret ->
        case Store.set_active(id, !secret.is_active) do
          {:ok, _secret} -> {:noreply, load_secrets(socket)}
          {:error, _reason} -> {:noreply, put_flash(socket, :error, "Failed to update key")}
        end
    end
  end

  def handle_event("delete_secret", %{"id" => id}, socket) do
    case Store.delete(id) do
      {:ok, _secret} ->
        {:noreply, socket |> load_secrets() |> put_flash(:info, "Crypto key destroyed")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to destroy key")}
    end
  end

  defp load_secrets(socket) do
    secrets = Store.list_all()

    socket
    |> assign(:secret_count, length(secrets))
    |> assign(:active_count, Enum.count(secrets, & &1.is_active))
    |> assign(:service_count, secrets |> Enum.map(& &1.service) |> Enum.uniq() |> length())
    |> assign(:secrets_empty?, secrets == [])
    |> assign(:secrets_by_id, Map.new(secrets, &{&1.id, &1}))
    |> stream(:secrets, secrets, reset: true)
  end

  defp secret_form(values \\ %{}) do
    defaults = %{"service" => "", "key" => "", "value" => "", "description" => ""}
    to_form(Map.merge(defaults, values), as: :secret)
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value), do: if(String.trim(value) == "", do: nil, else: value)

  defp timestamp(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%MZ")
  defp timestamp(_datetime), do: "UNKNOWN"
end
