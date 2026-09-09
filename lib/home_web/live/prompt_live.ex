defmodule HomeWeb.PromptLive do
  @moduledoc """
  Prompt management: list every brief prompt, create/edit/delete, and toggle
  enabled state. Each prompt can carry a `backend` (llm / agent_forge /
  opencode / claude_code / codex) and a schedule.
  """

  use HomeWeb, :live_view

  alias Home.Brief
  alias Home.Brief.Prompt

  on_mount {HomeWeb.LiveUserAuth, :live_user_optional}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Home.PubSub, Brief.topic())

    {:ok,
     socket
     |> assign_new(:current_scope, fn -> nil end)
     |> assign_new(:secret_count, fn -> 0 end)
     |> assign(:active_nav, :briefs)
     |> assign(:prompts, Brief.list_prompts())
     |> assign(:form, to_form(Brief.change_prompt(%Prompt{})))
     |> assign(:editing_id, nil)
     |> assign(:show_form, false)}
  end

  @impl true
  def handle_event("toggle_form", _params, socket) do
    {:noreply, assign(socket, :show_form, true)}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_form, false)
     |> assign(:editing_id, nil)
     |> assign(:form, to_form(Brief.change_prompt(%Prompt{})))}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    prompt = Brief.get_prompt!(id)

    {:noreply,
     socket
     |> assign(:form, to_form(Brief.change_prompt(prompt)))
     |> assign(:editing_id, prompt.id)
     |> assign(:show_form, true)}
  end

  def handle_event("save", %{"prompt" => params}, socket) do
    result =
      case socket.assigns.editing_id do
        nil ->
          Brief.create_prompt(params)

        id ->
          Brief.get_prompt!(id) |> Brief.update_prompt(params)
      end

    case result do
      {:ok, _prompt} ->
        {:noreply,
         socket
         |> put_flash(:info, "Prompt saved")
         |> assign(:form, to_form(Brief.change_prompt(%Prompt{})))
         |> assign(:editing_id, nil)
         |> assign(:show_form, false)
         |> assign(:prompts, Brief.list_prompts())}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("toggle_active", %{"id" => id}, socket) do
    prompt = Brief.get_prompt!(id)
    {:ok, _} = Brief.update_prompt(prompt, %{enabled: !prompt.enabled})

    {:noreply,
     socket
     |> assign(:prompts, Brief.list_prompts())}
  end

  def handle_event("run_now", %{"id" => id}, socket) do
    prompt = Brief.get_prompt!(id)

    case Brief.run_prompt_now(prompt) do
      {:ok, _brief} ->
        {:noreply,
         socket
         |> put_flash(:info, "Running #{prompt.name} now…")
         |> push_navigate(to: ~p"/briefs/#{prompt.slug}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not start #{prompt.name}")}
    end
  end

  def handle_event("delete_prompt", %{"id" => id}, socket) do
    prompt = Brief.get_prompt!(id)
    {:ok, _} = Brief.delete_prompt(prompt)

    {:noreply,
     socket
     |> put_flash(:info, "Prompt deleted")
     |> assign(:editing_id, nil)
     |> assign(:form, to_form(Brief.change_prompt(%Prompt{})))
     |> assign(:show_form, false)
     |> assign(:prompts, Brief.list_prompts())}
  end

  @impl true
  def handle_info({:briefs_updated, _kind, _brief}, socket) do
    {:noreply, assign(socket, :prompts, Brief.list_prompts())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp prompt_schedule(%Prompt{schedule: schedule}) do
    get_in(schedule, ["at"]) || "—"
  end

  defp schedule_at(form) do
    case get_in(form.params, ["schedule", "at"]) do
      nil ->
        case form[:schedule].value do
          %{"at" => at} -> at
          _ -> ""
        end

      at ->
        at
    end
  end
end
