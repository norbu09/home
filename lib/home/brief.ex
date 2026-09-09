defmodule Home.Brief do
  @moduledoc """
  Morning brief context: prompts, brief executions, and conversation messages.

  Follows the same facade pattern as `Home.Tactical` and `Home.Memory`:
  thin wrappers around Ecto queries, plus BRF-XXXX number allocation and
  PubSub broadcasts for the LiveView.
  """

  import Ecto.Query

  alias Home.Brief.{Conversation, Message, Prompt, Runner}
  alias Home.Repo

  require Logger

  @topic "briefs"

  # ── Queries ──────────────────────────────────────────────────────────────

  @doc "All briefs from today, sorted by prompt priority then insert time."
  def list_today do
    today = Date.utc_today()

    Conversation
    |> where([c], fragment("?::date = ?", c.inserted_at, ^today))
    |> join(:inner, [c], p in Prompt, on: c.prompt_id == p.id)
    |> order_by([c, p], asc: p.priority, asc: c.inserted_at)
    |> preload([c, p], prompt: p)
    |> Repo.all()
  end

  @doc "List briefs across a date range (inclusive), newest first."
  def list_range(%Date{} = from, %Date{} = to) do
    Conversation
    |> where(
      [c],
      fragment("?::date >= ? AND ?::date <= ?", c.inserted_at, ^from, c.inserted_at, ^to)
    )
    |> join(:inner, [c], p in Prompt, on: c.prompt_id == p.id)
    |> order_by([c], desc: c.inserted_at)
    |> preload([c, p], prompt: p)
    |> Repo.all()
  end

  @doc "Stats for today's briefs."
  def stats do
    today = Date.utc_today()

    rows =
      Conversation
      |> where([c], fragment("?::date = ?", c.inserted_at, ^today))
      |> select([c], %{
        status: c.status,
        count: count(c.id),
        cost_sum: sum(c.cost_usd)
      })
      |> group_by([c], c.status)
      |> Repo.all()

    counts = Map.new(rows, &{&1.status, &1.count})
    total_cost = rows |> Enum.map(&(&1.cost_sum || 0.0)) |> Enum.sum()

    %{
      total: rows |> Enum.map(& &1.count) |> Enum.sum(),
      open: Map.get(counts, "pending", 0) + Map.get(counts, "running", 0),
      pending: Map.get(counts, "pending", 0),
      running: Map.get(counts, "running", 0),
      completed: Map.get(counts, "completed", 0),
      reviewed: Map.get(counts, "reviewed", 0),
      dismissed: Map.get(counts, "dismissed", 0),
      failed: Map.get(counts, "failed", 0),
      cost_today: total_cost
    }
  end

  @doc "Get a brief by id. Raises if not found."
  def get!(id), do: Repo.get!(Conversation, id)

  @doc "All enabled prompts, sorted by priority (lowest first)."
  def list_enabled_prompts do
    Prompt
    |> where([p], p.enabled == true)
    |> order_by([p], asc: p.priority)
    |> Repo.all()
  end

  @doc """
  Next scheduled run among enabled prompts, as `%{at: Time.t(), prompt: Prompt.t(), next_day: boolean}`,
  or nil when no prompt has a schedule.
  """
  def next_run do
    now_time = DateTime.to_time(DateTime.utc_now())

    today =
      next_run_times()
      |> Enum.filter(fn {at, _prompt} -> Time.compare(at, now_time) != :lt end)
      |> Enum.min_by(&run_offset/1, fn -> nil end)

    case today do
      nil ->
        case next_run_times() |> Enum.min_by(&run_offset/1, fn -> nil end) do
          nil -> nil
          {at, prompt} -> %{at: at, prompt: prompt, next_day: true}
        end

      {at, prompt} ->
        %{at: at, prompt: prompt, next_day: false}
    end
  end

  defp next_run_times do
    for prompt <- list_enabled_prompts(),
        raw <- List.wrap(get_in(prompt.schedule, ["at"])),
        at <- List.wrap(parse_schedule_time(raw)) do
      {at, prompt}
    end
  end

  @doc false
  def parse_schedule_time("") do
    nil
  end

  def parse_schedule_time(time_str) do
    case time_str do
      <<hour::binary-size(2), ":", minute::binary-size(2)>> ->
        with {h, ""} <- Integer.parse(hour),
             {m, ""} <- Integer.parse(minute),
             true <- h >= 0 and h < 24 and m >= 0 and m < 60 do
          Time.new!(h, m, 0)
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp run_offset({at, _prompt}), do: Time.diff(at, ~T[00:00:00])

  @doc "Get a brief by id, or nil."
  def get_by_id(id) do
    Conversation
    |> Repo.get(id)
    |> maybe_preload()
  end

  @doc "The prompt associated with a given brief id."
  def prompt_for(brief_id) do
    brief = Repo.get!(Conversation, brief_id)
    Repo.get!(Prompt, brief.prompt_id)
  end

  @doc "ISO timestamp of last completed brief for a prompt, or \"never\"."
  def last_completed_at(prompt_id) do
    case Repo.one(
           from c in Conversation,
             where: c.prompt_id == ^prompt_id and c.status == "completed",
             order_by: [desc: c.completed_at],
             limit: 1,
             select: c.completed_at
         ) do
      nil -> "never"
      dt -> DateTime.to_iso8601(dt)
    end
  end

  @doc "Full conversation context for a brief: system prompt + stored messages."
  def full_conversation(%Conversation{} = brief) do
    prompt = Repo.get!(Prompt, brief.prompt_id)

    messages =
      Message
      |> where([m], m.brief_id == ^brief.id)
      |> order_by([m], asc: m.inserted_at)
      |> Repo.all()

    [
      %{"role" => "system", "content" => prompt.system_prompt}
      | Enum.map(messages, fn m -> %{"role" => m.role, "content" => m.content} end)
    ]
  end

  # ── Mutations ────────────────────────────────────────────────────────────

  @doc "Create a new brief. Allocates a BRF-XXXX number and broadcasts."
  def create(attrs) do
    %Conversation{}
    |> Conversation.changeset(Map.put_new_lazy(attrs, :number, fn -> allocate_number!() end))
    |> Repo.insert()
    |> tap_ok(fn brief -> broadcast({:briefs_updated, :created, brief}) end)
  end

  @doc """
  Run a prompt now, outside its schedule: insert a running brief and execute
  the runner in a fire-and-forget task. The outcome (or failure) broadcasts
  on the briefs topic, so any subscribed LiveView refreshes. Pass
  `retried_from_id:` to link a manual retry to the brief it re-runs.
  """
  def run_prompt_now(%Prompt{} = prompt, opts \\ []) do
    case create(%{
           prompt_id: prompt.id,
           status: "running",
           scheduled_at: DateTime.utc_now(),
           retried_from_id: opts[:retried_from_id]
         }) do
      {:ok, brief} ->
        Task.start(fn ->
          prompt = prompt_for(brief.id)
          Runner.run(prompt, brief)
        end)

        {:ok, brief}

      {:error, _} = error ->
        error
    end
  end

  @doc "Insert-or-ignore a prompt. Raises on conflict (slug)."
  def create_prompt!(attrs) do
    %Prompt{}
    |> Prompt.changeset(attrs)
    |> Repo.insert!(on_conflict: :nothing)
  end

  @doc "All prompts, sorted by priority (lowest first), newest ties last."
  def list_prompts do
    Prompt
    |> order_by([p], asc: p.priority, asc: p.name)
    |> preload(:briefs)
    |> Repo.all()
  end

  @doc "Get a prompt by id. Raises if not found."
  def get_prompt!(id), do: Repo.get!(Prompt, id)

  @doc "Get a prompt by id, or nil."
  def get_prompt(id) do
    case Repo.get(Prompt, id) do
      nil -> nil
      prompt -> Repo.preload(prompt, :briefs)
    end
  end

  @doc "A prompt changeset for creation/editing forms."
  def change_prompt(%Prompt{} = prompt, attrs \\ %{}) do
    Prompt.changeset(prompt, attrs)
  end

  @doc "Create a prompt from a changeset. Returns `{:ok, prompt}` or `{:error, changeset}`."
  def create_prompt(attrs) do
    %Prompt{}
    |> Prompt.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Update a prompt. Returns `{:ok, prompt}` or `{:error, changeset}`."
  def update_prompt(%Prompt{} = prompt, attrs) do
    prompt
    |> Prompt.changeset(attrs)
    |> Repo.update()
  end

  @doc "Delete a prompt. Returns `{:ok, prompt}` or `{:error, changeset}`."
  def delete_prompt(%Prompt{} = prompt) do
    Repo.delete(prompt)
  end

  @doc "Update a brief. Broadcasts on success."
  def update_brief(%Conversation{} = brief, attrs) do
    brief
    |> Conversation.changeset(attrs)
    |> Repo.update()
    |> tap_ok(fn brief -> broadcast({:briefs_updated, :updated, brief}) end)
  end

  @doc "Mark a brief as failed with a human-readable error reason."
  def fail(%Conversation{} = brief, reason) do
    update_brief(brief, %{
      status: "failed",
      error: human_error(reason),
      completed_at: DateTime.utc_now()
    })
  end

  defp human_error(error) when is_binary(error), do: error
  defp human_error(error), do: inspect(error)

  @doc "Add a message to a brief's conversation."
  def add_message(%Conversation{} = brief, role, content)
      when role in ~w(system user assistant) do
    %Message{}
    |> Message.changeset(%{
      brief_id: brief.id,
      role: role,
      content: content
    })
    |> Repo.insert()
    |> tap_ok(fn msg ->
      Phoenix.PubSub.broadcast(Home.PubSub, topic(brief), {:brief_message, msg})
    end)
  end

  @doc "Review a brief (mark as reviewed, typically with notes)."
  def review(%Conversation{} = brief, notes \\ nil) do
    update_brief(brief, %{
      status: "reviewed",
      reviewed_at: DateTime.utc_now(),
      review_notes: notes
    })
  end

  @doc "Dismiss a brief (won't appear in future meetings)."
  def dismiss(%Conversation{} = brief) do
    update_brief(brief, %{status: "dismissed"})
  end

  @doc "Per-brief PubSub topic for message-level events."
  def topic(%Conversation{} = brief), do: "brief:#{brief.id}"
  def topic, do: @topic

  # ── Number allocation ────────────────────────────────────────────────────

  @doc """
  Allocate the next BRF-XXXX number. Runs in a transaction; retries once
  on a rare race collision (unique index).
  """
  def allocate_number! do
    max_num = max_number()

    next =
      (max_num + 1)
      |> to_string()
      |> String.pad_leading(4, "0")
      |> then(&"BRF-#{&1}")

    next
  end

  defp max_number do
    case Repo.one(
           from c in Conversation,
             where: not is_nil(c.number),
             select:
               fragment(
                 "COALESCE(MAX(NULLIF(regexp_replace(?, '\\D', '', 'g'), '')::int), 0)",
                 c.number
               )
         ) do
      nil -> 0
      num when is_integer(num) -> num
      num -> num |> to_string() |> Integer.parse() |> elem(0)
    end
  end

  # ── PubSub ───────────────────────────────────────────────────────────────

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(Home.PubSub, @topic, event)
  rescue
    ArgumentError -> :ok
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp maybe_preload(nil), do: nil

  defp maybe_preload(brief) do
    brief
    |> Repo.preload([:prompt, :messages])
  end

  defp tap_ok({:ok, _} = result, fun) do
    fun.(elem(result, 1))
    result
  end

  defp tap_ok(error, _fun), do: error
end
