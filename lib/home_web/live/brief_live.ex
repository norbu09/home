defmodule HomeWeb.BriefLive do
  @moduledoc """
  Morning brief hub: today's queue, the meeting-mode walkthrough
  (approve/skip/dismiss per brief), per-brief retry, multi-turn discussion,
  and past briefs grouped by day. A `:detail` mode deep-dives the latest
  brief for a prompt slug.
  """

  use HomeWeb, :live_view

  import Ecto.Query

  alias Home.Brief
  alias Home.Brief.{Conversation, Insights, Message, Prompt, Runner}
  alias Home.LLMProxy
  alias Home.Settings

  on_mount {HomeWeb.LiveUserAuth, :live_user_optional}

  @impl true
  def mount(%{"slug" => slug} = _params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Home.PubSub, Brief.topic())

    {:ok,
     socket
     |> assign_new(:current_scope, fn -> nil end)
     |> assign_new(:secret_count, fn -> 0 end)
     |> assign(:active_nav, :briefs)
     |> assign(:detail_mode, true)
     |> assign(:meeting_active, false)
     |> assign(:brief_index, 0)
     |> assign(:pending_response, false)
     |> assign(:discussion_form, to_form(%{"message" => ""}))
     |> assign(:brief, latest_brief_for_slug(slug))
     |> assign_brief_state()}
  end

  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Home.PubSub, Brief.topic())

    {:ok,
     socket
     |> assign_new(:current_scope, fn -> nil end)
     |> assign_new(:secret_count, fn -> 0 end)
     |> assign(:active_nav, :briefs)
     |> assign(:detail_mode, false)
     |> assign(:meeting_active, false)
     |> assign(:brief_index, 0)
     |> assign(:pending_response, false)
     |> assign(:discussion_form, to_form(%{"message" => ""}))
     |> assign(:current_brief, nil)
     |> assign_brief_state()}
  end

  # ── Meeting controls ──────────────────────────────────────────────────

  @impl true
  def handle_event("start_meeting", _params, socket) do
    case meeting_briefs(socket.assigns.briefs) do
      [] ->
        {:noreply, socket}

      _list ->
        {:noreply,
         socket
         |> assign(:meeting_active, true)
         |> assign(:brief_index, 0)
         |> assign(:discussion_form, to_form(%{"message" => ""}))
         |> assign(:pending_response, false)
         |> assign_brief_state()}
    end
  end

  def handle_event("end_meeting", _params, socket) do
    {:noreply,
     socket
     |> assign(:meeting_active, false)
     |> assign(:brief_index, 0)
     |> assign(:discussion_form, to_form(%{"message" => ""}))
     |> assign(:pending_response, false)
     |> assign_brief_state()}
  end

  def handle_event("advance_brief", _params, socket) do
    if brief = socket.assigns.current_brief, do: Brief.review(brief, nil)
    {:noreply, advance(socket)}
  end

  def handle_event("skip_brief", _params, socket), do: {:noreply, advance(socket)}

  def handle_event("dismiss_brief", _params, socket) do
    if brief = socket.assigns.current_brief, do: Brief.dismiss(brief)
    {:noreply, advance(socket)}
  end

  def handle_event("retry_brief", %{"id" => id}, socket) do
    brief = Brief.get_by_id(id)

    if brief && brief.status == "failed" do
      prompt = Brief.prompt_for(brief.id)

      case Brief.create(%{
             prompt_id: prompt.id,
             status: "running",
             scheduled_at: DateTime.utc_now(),
             retried_from_id: brief.id
           }) do
        {:ok, retry} ->
          Task.start(fn ->
            prompt = Brief.prompt_for(retry.id)
            Runner.run(prompt, retry)
          end)

          {:noreply, assign_brief_state(socket)}

        {:error, _} ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("send_discussion", %{"message" => text}, socket) do
    text = String.trim(to_string(text || ""))
    brief = socket.assigns.current_brief

    if text != "" and not socket.assigns.pending_response and not is_nil(brief) do
      Brief.add_message(brief, "user", text)

      model = brief.prompt.model || "coder"
      messages = Brief.full_conversation(brief)
      caller = self()

      Task.start(fn ->
        result =
          LLMProxy.chat_completion(
            %{"model" => model, "messages" => messages, "temperature" => 0.3},
            project: "briefs",
            tool: "brief"
          )

        send(caller, {:brief_discussion, self(), result})
      end)

      {:noreply,
       socket
       |> assign(:pending_response, true)
       |> assign(:discussion_form, to_form(%{"message" => ""}))}
    else
      {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ── PubSub events ─────────────────────────────────────────────────────

  @impl true
  def handle_info({:briefs_updated, _kind, _brief}, socket), do: {:noreply, refresh(socket)}

  def handle_info({:brief_completed, _brief}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:brief_failed, _brief, _reason}, socket), do: {:noreply, refresh(socket)}

  def handle_info({:brief_discussion, _task, {:ok, response}}, socket) do
    if brief = socket.assigns.current_brief do
      case extract_content(response) do
        {:ok, content} -> Brief.add_message(brief, "assistant", content)
        :error -> :ok
      end
    end

    {:noreply, socket |> assign(:pending_response, false) |> refresh()}
  end

  def handle_info({:brief_discussion, _task, {:error, _reason}}, socket) do
    {:noreply, socket |> assign(:pending_response, false) |> refresh()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── State assembly ────────────────────────────────────────────────────

  defp refresh(socket) do
    if socket.assigns.detail_mode do
      slug =
        socket.assigns.brief && socket.assigns.brief.prompt && socket.assigns.brief.prompt.slug

      socket |> assign(:brief, latest_brief_for_slug(slug)) |> assign_brief_state()
    else
      assign_brief_state(socket)
    end
  end

  defp assign_brief_state(socket) do
    briefs = Brief.list_today()

    current_brief =
      cond do
        socket.assigns.detail_mode ->
          socket.assigns.brief

        socket.assigns.meeting_active ->
          case meeting_briefs(briefs) |> Enum.at(socket.assigns.brief_index) do
            nil -> nil
            target -> Brief.get_by_id(target.id) || target
          end

        true ->
          socket.assigns.current_brief
      end

    from = Date.add(Date.utc_today(), -6)

    past_briefs =
      briefs
      |> Kernel.++(Brief.list_range(from, Date.add(Date.utc_today(), -1)))
      |> Enum.group_by(&DateTime.to_date(&1.inserted_at))

    scheduler =
      try do
        Home.Brief.Scheduler.status()
      catch
        :exit, _ -> %{running?: false}
      end

    socket
    |> assign(:briefs, briefs)
    |> assign(:current_brief, current_brief)
    |> assign(:stats, Brief.stats())
    |> assign(:brief_insights, Insights.by_prompt())
    |> assign(:past_briefs, past_briefs)
    |> assign(:scheduler_enabled, Settings.get_bool("brief_scheduler.enabled", false))
    |> assign(:scheduler_running?, Map.get(scheduler, :running?, false))
  end

  defp meeting_briefs(briefs), do: Enum.filter(briefs, &(&1.status == "completed"))

  defp meeting_progress(index, briefs), do: "#{index + 1} / #{length(meeting_briefs(briefs))}"

  defp advance(socket) do
    count = meeting_briefs(socket.assigns.briefs) |> length()

    socket =
      if socket.assigns.brief_index + 1 >= count do
        socket
        |> assign(:meeting_active, false)
        |> assign(:brief_index, 0)
      else
        assign(socket, :brief_index, socket.assigns.brief_index + 1)
      end

    socket
    |> assign(:discussion_form, to_form(%{"message" => ""}))
    |> assign(:pending_response, false)
    |> assign_brief_state()
  end

  defp latest_brief_for_slug(nil), do: nil

  defp latest_brief_for_slug(slug) do
    messages_query = from(m in Message, order_by: [asc: m.inserted_at])

    Home.Repo.one(
      from c in Conversation,
        join: p in Prompt,
        on: c.prompt_id == p.id,
        where: p.slug == ^slug,
        order_by: [desc: c.inserted_at],
        limit: 1,
        preload: [prompt: p, messages: ^messages_query]
    )
  end

  defp extract_content(%{
         choices: [%{message: %{content: content}} | _]
       })
       when is_binary(content),
       do: {:ok, content}

  defp extract_content(_), do: :error

  # ── Shared display helpers ────────────────────────────────────────────

  defp usd(nil), do: "—"

  defp usd(n) when is_number(n), do: "$" <> :erlang.float_to_binary(n / 1, decimals: 2)

  defp format_time(nil), do: "—"
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M UTC")

  defp pipeline_label(briefs) do
    done = Enum.count(briefs, &(&1.status in ["completed", "reviewed"]))
    running = Enum.count(briefs, &(&1.status in ["pending", "running"]))
    failed = Enum.count(briefs, &(&1.status == "failed"))

    Enum.join(
      Enum.reject(
        [
          "#{done} completed",
          running > 0 && "#{running} running",
          failed > 0 && "#{failed} failed"
        ],
        &is_nil/1
      ),
      " · "
    ) || "0 briefs"
  end

  defp status_atom("completed"), do: :completed
  defp status_atom("reviewed"), do: :completed
  defp status_atom("running"), do: :running
  defp status_atom("pending"), do: :pending
  defp status_atom("failed"), do: :failed
  defp status_atom("dismissed"), do: :archived
  defp status_atom(_), do: :ghost

  defp status_dot("failed"), do: "bg-error"
  defp status_dot("reviewed"), do: "bg-success"
  defp status_dot("dismissed"), do: "bg-base-content/30"
  defp status_dot("running"), do: "bg-warning animate-pulse"
  defp status_dot(_), do: "bg-info"

  attr :brief, :map, required: true

  def brief_card_row(assigns) do
    ~H"""
    <div
      id={"brief-row-#{@brief.id}"}
      class={[
        "flex flex-col sm:flex-row sm:items-center gap-2 px-3 py-2 rounded-lg",
        "hover:bg-base-200/40 transition-colors",
        @brief.status == "reviewed" && "opacity-70"
      ]}
    >
      <div class="flex items-center gap-2 min-w-0 flex-1">
        <.status_badge status={status_atom(@brief.status)} />
        <div class="min-w-0">
          <div class="text-sm font-medium truncate">{@brief.prompt.name}</div>
          <div class="text-xs text-base-content/40">
            {@brief.number} · {format_time(@brief.completed_at)}
          </div>
        </div>
      </div>

      <div class="flex items-center gap-2 shrink-0">
        <%= if @brief.cost_usd do %>
          <span class="text-xs text-base-content/40">{usd(@brief.cost_usd)}</span>
        <% end %>
        <%= if @brief.status == "failed" do %>
          <button
            id={"retry-brief-#{@brief.id}"}
            class="btn btn-xs btn-outline btn-error"
            phx-click="retry_brief"
            phx-value-id={@brief.id}
          >
            <.icon name="hero-arrow-path" class="size-3" /> Retry
          </button>
          <.link
            href={~p"/briefs/#{@brief.prompt.slug}"}
            class="btn btn-xs btn-ghost"
            aria-label="View failed brief"
          >
            <.icon name="hero-eye" class="size-3" />
          </.link>
        <% end %>
        <%= if @brief.status in ["completed", "reviewed"] do %>
          <.link
            href={~p"/briefs/#{@brief.prompt.slug}"}
            class="btn btn-xs btn-ghost"
            aria-label={"Open #{@brief.prompt.name}"}
          >
            <.icon name="hero-chevron-right" class="size-3" />
          </.link>
        <% end %>
      </div>
    </div>
    """
  end

  attr :brief, :map, required: true
  attr :interactive, :boolean, default: false
  attr :form, :map, default: nil
  attr :pending_response, :boolean, default: false

  def full_brief_card(assigns) do
    ~H"""
    <div id={"brief-card-#{@brief.id}"} class="space-y-5">
      <div class="flex flex-wrap items-center gap-2">
        <.status_badge status={status_atom(@brief.status)} />
        <span class="text-xs text-base-content/40">{@brief.number}</span>
        <%= if @brief.cost_usd do %>
          <span class="text-xs text-base-content/40">{usd(@brief.cost_usd)}</span>
        <% end %>
        <%= if @brief.model_used do %>
          <span class="text-xs text-base-content/30">{@brief.model_used}</span>
        <% end %>
        <%= if @brief.retried_from_id do %>
          <span class="text-xs text-base-content/40">retry lineage</span>
        <% end %>
      </div>

      <%= if @brief.status == "failed" do %>
        <div class="alert alert-error text-sm">
          <.icon name="hero-exclamation-triangle" class="size-4" />
          <div>
            <div class="font-bold">FAILED</div>
            <div class="opacity-80">{@brief.error}</div>
          </div>
          <button
            class="btn btn-xs btn-outline btn-error"
            phx-click="retry_brief"
            phx-value-id={@brief.id}
          >
            <.icon name="hero-arrow-path" class="size-3" /> Retry
          </button>
        </div>
      <% end %>

      <%= if @brief.summary do %>
        <div class="text-lg font-semibold leading-snug">{@brief.summary}</div>
      <% end %>

      <%= if @brief.outcome && @brief.status != "failed" do %>
        <div class="rounded-lg bg-base-200/30 p-4 whitespace-pre-wrap text-sm leading-relaxed">
          {@brief.outcome}
        </div>
      <% end %>

      <%= if @brief.next_steps && @brief.next_steps != [] do %>
        <div>
          <div class="text-xs tracking-widest uppercase text-base-content/40 mb-2">Next steps</div>
          <ul id={"next-steps-#{@brief.id}"} class="space-y-1">
            <%= for step <- @brief.next_steps do %>
              <li class="flex items-start gap-2 text-sm">
                <span class="text-primary mt-0.5">▸</span>
                <span>{step}</span>
              </li>
            <% end %>
          </ul>
        </div>
      <% end %>

      <%= if @interactive do %>
        <.discussion_block
          brief={@brief}
          form={@form || discussion_form_for(@brief)}
          pending_response={@pending_response}
        />
      <% end %>
    </div>
    """
  end

  attr :brief, :map, required: true
  attr :form, :map, required: true
  attr :pending_response, :boolean, default: false

  def discussion_block(assigns) do
    ~H"""
    <div id={"discussion-#{@brief.id}"} class="space-y-3">
      <div class="flex items-center justify-between">
        <div class="text-xs tracking-widest uppercase text-base-content/40">Discussion</div>
        <%= if @pending_response do %>
          <span class="text-xs text-warning animate-pulse">thinking…</span>
        <% end %>
      </div>

      <div
        id={"discussion-thread-#{@brief.id}"}
        class="space-y-3 max-h-80 overflow-y-auto pr-1"
      >
        <%= if Enum.empty?(@brief.messages || []) do %>
          <div class="text-sm text-base-content/40 italic">
            No discussion yet — ask a question or start the meeting.
          </div>
        <% end %>
        <%= for message <- Enum.sort_by(@brief.messages || [], & &1.inserted_at) do %>
          <div class={[
            "flex",
            message.role == "user" && "justify-end",
            message.role == "assistant" && "justify-start"
          ]}>
            <div class={[
              "max-w-[85%] rounded-lg px-3 py-2 text-sm whitespace-pre-wrap",
              message.role == "user" && "bg-primary/15 border border-primary/20",
              message.role == "assistant" && "bg-base-200/40"
            ]}>
              {message.content}
            </div>
          </div>
        <% end %>
      </div>

      <.form
        for={@form}
        id={"discussion-form-#{@brief.id}"}
        phx-submit="send_discussion"
        class="flex gap-2 items-end"
      >
        <.input
          type="textarea"
          field={@form[:message]}
          rows={1}
          placeholder="Add to discussion… (Enter shift+? not supported)"
          class="w-full min-h-[2.5rem] resize-none"
        />
        <button
          id={"discussion-send-#{@brief.id}"}
          class="btn btn-primary btn-sm"
          type="submit"
          disabled={@pending_response}
        >
          <.icon name="hero-paper-airplane" class="size-4" /> Send
        </button>
      </.form>
    </div>
    """
  end

  defp discussion_form_for(_brief), do: to_form(%{"message" => ""})
end
