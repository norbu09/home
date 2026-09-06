# Morning Brief: Scheduled Prompt Execution & Daily Meeting

> Design document — 2026-09-06
> Status: Draft

## Context

Home is a personal operations center — LLM routing, agent memory, tactical dashboards. The missing piece is **proactive daily intelligence**: a system that runs pre-defined research prompts on a schedule, synthesises the results, and presents them in a structured "morning meeting" where each topic is discussed, next steps are captured, and the user moves on.

The homunculus project (`../homunculus`) has a related concept: its `Heartbeat.Process` fires periodic tasks into workspace agents, and a Review Mode lets the user walk through workspaces one by one. That system is tightly coupled to homunculus's multi-agent/multi-workspace/firecracker architecture. Home needs something lighter — a single-user, single-agent flow that reuses the existing LLM proxy and memory system.

## Goals

1. **Scheduled prompt execution** — user-defined prompts run at configurable times (e.g. 08:00 daily), in parallel.
2. **Research outcome** — each prompt produces a structured brief (analysis, recommendations, next steps) stored as a conversation.
3. **Morning meeting** — a LiveView that walks through all open briefs, lets the user discuss each with an agent, agree next steps, then advance to the next.
4. **Lightweight** — no new external dependencies. Builds on the existing LLM proxy, memory system, and Settings store. No Oban, no Firecracker, no multi-agent orchestration.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                     BriefScheduler (GenServer)               │
│  tick every 60s → checks clock against prompt schedules     │
│  fires Task.async_stream for due prompts (parallel)         │
└──────────┬──────────────────────────┬───────────────────────┘
           │ :prompt_due              │ :brief_ready / :brief_failed
           ▼                          ▼
┌──────────────────────┐  ┌──────────────────────────────────┐
│  BriefRunner (Task)  │  │  BriefLive (LiveView)            │
│  Builds messages,    │  │  /briefs → meeting UI            │
│  calls LLM proxy,    │  │  Shows queue, brief cards,       │
│  stores outcome in   │  │  discussion thread, next steps   │
│  briefs table        │  └──────────────────────────────────┘
└──────────────────────┘
```

### Module Map

| Module | Type | Responsibility |
|--------|------|----------------|
| `Home.Brief` | Context facade | CRUD + lifecycle for briefs and prompts |
| `Home.Brief.Prompt` | Ecto schema | A pre-defined prompt with schedule, system prompt, and category |
| `Home.Brief.Conversation` | Ecto schema | One prompt execution: input, LLM response, status, outcome |
| `Home.Brief.Message` | Ecto schema | Individual messages within a brief conversation (user/assistant/system) |
| `Home.Brief.Scheduler` | GenServer | Clock tick, fires due prompts via `Task.async_stream` |
| `Home.Brief.Runner` | Pure module | Builds prompt messages, calls LLM proxy, parses response |
| `Home.Brief.Insights` | Pure module | Per-prompt execution health + discussion outcome rollups |
| `HomeWeb.BriefLive` | LiveView | Morning meeting UI: queue, brief cards, discussion, next steps |
| `HomeWeb.BriefLive.DetailLive` | LiveView | Individual brief detail / deep-dive view |

## Data Model

### `brief_prompts`

Defines the pre-configured research prompts.

| Column | Type | Notes |
|--------|------|-------|
| `id` | binary_id PK | |
| `name` | varchar(255) | Human label: "Daily Calendar Check" |
| `slug` | varchar(255) | Unique, URL-safe: "daily-calendar" |
| `category` | varchar(100) | `calendar`, `email`, `infrastructure`, `planning`, `custom` |
| `system_prompt` | text | The system-level instruction that shapes the LLM's persona and output format |
| `user_prompt` | text | The research query, may contain `{{date}}` and `{{last_run}}` template vars |
| `schedule` | jsonb | `%{"at" => "08:00"}` or `%{"every_ms" => 3600000}` |
| `enabled` | boolean | Default `true`. Toggle without deleting |
| `run_weekends` | boolean | Default `false`. `at`-type schedules skip Sat/Sun when false |
| `priority` | integer | Lower = shown first in meeting queue. Default 100 |
| `model` | varchar(255) | LLM model override, or `nil` for default (`coder` role chain) |
| `metadata` | jsonb | Freeform config (e.g. email folder to check, calendar API endpoint) |
| `inserted_at` | utc_datetime_usec | |
| `updated_at` | utc_datetime_usec | |

**Indexes**: unique on `slug`.

### `briefs`

One row per prompt execution. The "conversation" that the morning meeting walks through.

| Column | Type | Notes |
|--------|------|-------|
| `id` | binary_id PK | |
| `prompt_id` | references `brief_prompts` | |
| `status` | varchar(50) | `pending`, `running`, `completed`, `failed`, `reviewed`, `dismissed` |
| `outcome` | text | LLM's structured response (markdown with recommendations) |
| `summary` | varchar(500) | One-line extraction for queue display |
| `next_steps` | jsonb | `["Step 1", "Step 2"]` — extracted from outcome or added during meeting |
| `action_items` | jsonb | `[%{text: "...", status: "open", assigned: nil}]` — concrete tasks |
| `reviewed_at` | utc_datetime_usec | Set when user advances past this brief in the meeting |
| `review_notes` | text | User's notes from the discussion |
| `error` | text | Human-readable failure reason if status is `failed` |
| `scheduled_at` | utc_datetime_usec | When this execution was triggered |
| `completed_at` | utc_datetime_usec | When the LLM response finished |
| `model_used` | varchar(255) | Which model actually served the request |
| `cost_usd` | float | LLM cost for this execution |
| `number` | varchar(20) | Unique human reference, e.g. `BRF-0001` (backlog-style numbering) |
| `retried_from` | references `briefs` | If this execution was a manual retry, the failed brief it replaces |
| `metadata` | jsonb | Freeform |
| `inserted_at` | utc_datetime_usec | |
| `updated_at` | utc_datetime_usec | |

**Indexes**: on `status` + `inserted_at` (queue queries), on `prompt_id`, on `reviewed_at`. Unique on `number`.

### `brief_messages`

Individual messages within a brief's conversation. Supports multi-turn discussion during the meeting.

| Column | Type | Notes |
|--------|------|-------|
| `id` | binary_id PK | |
| `brief_id` | references `briefs` | |
| `role` | varchar(20) | `system`, `user`, `assistant` |
| `content` | text | |
| `cost_usd` | float | Only on `assistant` messages |
| `model_used` | varchar(255) | |
| `inserted_at` | utc_datetime_usec | |

**Indexes**: on `brief_id` + `inserted_at`.

### Migration

```elixir
defmodule Home.Repo.Migrations.CreateBriefs do
  use Ecto.Migration

  def change do
    create table(:brief_prompts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :category, :string, null: false, default: "custom"
      add :system_prompt, :text, null: false
      add :user_prompt, :text, null: false
      add :schedule, :map, null: false, default: "{}"
      add :enabled, :boolean, null: false, default: true
      add :run_weekends, :boolean, null: false, default: false
      add :priority, :integer, null: false, default: 100
      add :model, :string
      add :metadata, :map, null: false, default: "%{}"
      timestamps()
    end

    create unique_index(:brief_prompts, [:slug])

    create table(:briefs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :prompt_id, references(:brief_prompts, type: :binary_id), null: false
      add :status, :string, null: false, default: "pending"
      add :outcome, :text
      add :summary, :string, size: 500
      add :next_steps, :map, null: false, default: "[]"
      add :action_items, :map, null: false, default: "[]"
      add :reviewed_at, :utc_datetime_usec
      add :review_notes, :text
      add :error, :text
      add :scheduled_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :model_used, :string
      add :cost_usd, :float
      add :number, :string
      add :retried_from, references(:briefs, type: :binary_id)
      add :metadata, :map, null: false, default: "%{}"
      timestamps()
    end

    create index(:briefs, [:status, :inserted_at])
    create index(:briefs, [:prompt_id])
    create index(:briefs, [:reviewed_at])
    create unique_index(:briefs, [:number])

    create table(:brief_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :brief_id, references(:briefs, type: :binary_id), null: false
      add :role, :string, null: false
      add :content, :text, null: false
      add :cost_usd, :float
      add :model_used, :string
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:brief_messages, [:brief_id, :inserted_at])
  end
end
```

## Scheduling

### BriefScheduler GenServer

Follows the same pattern as `Home.Memory.ImportScheduler` — a self-rescheduling `Process.send_after` tick loop.

```elixir
defmodule Home.Brief.Scheduler do
  use GenServer

  @tick_interval :timer.seconds(60)

  # State
  defstruct [
    :running_task,      # Task.t() | nil — currently executing batch
    :last_tick_at,      # DateTime.t()
    :last_fired_at,     # DateTime.t() — when prompts were last fired
    fired_ids: MapSet.new()  # Prompt IDs already fired this cycle (dedup)
  ]
end
```

**Tick logic**:

1. Load all enabled `brief_prompts` from DB.
2. For each prompt, evaluate its `schedule` against current time:
   - `%{"at" => "HH:MM"}` — fire if current UTC time matches (hour:minute) AND this prompt hasn't fired today. If `run_weekends` is `false`, `at`-type schedules skip Saturday and Sunday.
   - `%{"every_ms" => ms}` — fire if `now - last_fired_at >= ms`.
3. Collect due prompts into a batch.
4. If batch non-empty and no `running_task`:
   - `Task.async_stream(batches, &BriefRunner.run/1, max_concurrency: @max_concurrency, timeout: 120_000)`
   - Subscribe to task messages via `Task.async` + `handle_info({ref, result})`.
5. On completion, broadcast `{:briefs_updated, summary}` on the `"briefs"` PubSub topic.
6. Reset `fired_ids` at midnight (new day).

**Dedup**: The `fired_ids` MapSet prevents double-firing within a single day for `at`-type schedules. It resets when the date rolls over.

### Concurrency

Prompts fire at the LLM provider's concurrency limit, capped at 5:

```elixir
@max_concurrency 5

defp concurrency_limit do
  ProviderHealth.concurrency_limit() |> min(@max_concurrency)
end
```

The scheduler reads the provider's allowed concurrency from `Home.LLMProxy.ProviderHealth` and runs the batch with `max_concurrency: concurrency_limit()`. This respects provider rate limits while keeping the batch parallel.

### Schedule Evaluation

```elixir
defp due?(%{"at" => time_str, "run_weekends" => true}, now, last_fired) do
  # ... weekend included
end

defp due?(%{"at" => time_str}, now, last_fired) do
  {h, m} = parse_time(time_str)
  weekend? = now.day_of_week in [6, 7]  # Sat = 6, Sun = 7

  # Skip weekends unless run_weekends, and only if we haven't already fired today
  not weekend? and now.hour == h and now.minute == m and
    Date.diff(now.date, last_fired.date) > 0
end

defp due?(%{"every_ms" => interval_ms}, now, last_fired) do
  DateTime.diff(now, last_fired, :millisecond) >= interval_ms
end
```

### Configuration via Settings

| Setting | Default | Purpose |
|---------|---------|---------|
| `brief_scheduler.enabled` | `false` | Master toggle |
| `brief_scheduler.initial_delay_ms` | `60_000` | Delay before first tick after boot |

Exposed in the `/settings` LiveView alongside the existing memory import toggle.

## Prompt Execution (BriefRunner)

A pure module that takes a `brief_prompt` + `brief` record, builds the LLM request, and stores the result.

```elixir
defmodule Home.Brief.Runner do
  @spec run(Brief.Prompt.t(), Brief.t()) :: {:ok, Brief.t()} | {:error, term()}
  def run(prompt, brief) do
    messages = build_messages(prompt, brief)

    with {:ok, response} <- call_llm(messages, prompt.model),
         {:ok, parsed} <- parse_response(response) do
      Brief.update(brief, %{
        status: "completed",
        outcome: parsed.outcome,
        summary: parsed.summary,
        next_steps: parsed.next_steps,
        completed_at: DateTime.utc_now(),
        model_used: response.model,
        cost_usd: response.cost
      })
    else
      {:error, reason} ->
        Brief.fail(brief, reason)
    end
  end
end
```

### Message Construction

```elixir
defp build_messages(prompt, brief) do
  now = DateTime.utc_now() |> DateTime.to_date()
  last_run = Brief.last_completed_at(prompt.id)

  user_prompt =
    prompt.user_prompt
    |> String.replace("{{date}}, Date.to_string(now))
    |> String.replace("{{last_run}}", last_run || "never")

  [
    %{"role" => "system", "content" => prompt.system_prompt},
    %{"role" => "user", "content" => user_prompt}
  ]
end
```

### LLM Call

Uses the existing proxy directly — no new HTTP infrastructure needed:

```elixir
defp call_llm(messages, model_override) do
  model = model_override || "coder"

  body = %{
    "model" => model,
    "messages" => messages,
    "temperature" => 0.4,
    "max_tokens" => 4096
  }

  case Home.LLMProxy.chat_completion(body, project: "briefs", tool: "brief") do
    {:ok, %{"choices" => [%{"message" => %{"content" => content}} | _], "model" => model} = resp} ->
      cost = extract_cost(resp)
      {:ok, %{content: content, model: model, cost: cost}}

    {:error, reason} ->
      {:error, reason}
  end
end
```

### Response Parsing

The LLM is instructed (via `system_prompt`) to return structured markdown:

```markdown
## Summary
One-paragraph overview.

## Key Findings
- Finding 1
- Finding 2

## Recommendations
1. Do X
2. Do Y

## Next Steps
- [ ] Action item 1
- [ ] Action item 2
```

The runner extracts `summary` (first paragraph), `next_steps` (lines starting with `- [ ]`), and stores the full markdown as `outcome`.

### Failure Handling

When the LLM call fails (provider down, timeout, rate limit), the brief is not silently retried:

1. **Status set to `failed`**, with `error` storing a human-readable reason (`"provider zai/glm-5.2 unreachable: connection timeout"`).
2. **PubSub broadcast** `{:brief_failed, brief, reason}` so the UI updates in real-time.
3. **UI flags it** — the brief card shows a `⚑ FAILED` badge with the reason and a **Retry** button.
4. **Manual re-trigger**: the user clicks Retry, which creates a fresh brief attempt for the same prompt:

```elixir
def handle_event("retry_brief", %{"id" => brief_id}, socket) do
  prompt = Brief.prompt_for(brief_id)

  {:ok, brief} = Brief.create(%{
    prompt_id: prompt.id,
    status: "running",
    scheduled_at: DateTime.utc_now(),
    retried_from: brief_id
  })

  Task.async(fn -> BriefRunner.run(prompt, brief) end)

  {:noreply, assign(socket, :briefs, Brief.list_today())}
end
```

5. No auto-retry — a failed morning brief waits for the user to re-trigger it or for the next scheduled run (`fired_ids` only marks fired prompts that actually started, so a failed run does not block the next day's schedule).

Note: `retried_from` points at the failed brief, so the UI can link back to the original failure for comparison.

## Default Prompts

Seeded via a migration or `priv/repo/seeds.exs`:

### Daily Calendar Check
```yaml
name: Daily Calendar Check
slug: daily-calendar
category: calendar
schedule: {at: "08:00", run_weekends: true}
priority: 10
system_prompt: |
  You are a personal scheduling assistant. Analyse the user's calendar
  for today and provide:
  - A timeline of meetings and events
  - Preparation needed for each meeting
  - Potential conflicts or double-bookings
  - Suggested focus blocks between meetings
  Format as structured markdown with clear sections.
user_prompt: |
  Check my calendar for {{date}}. What does my day look like?
  What do I need to prepare? Are there any scheduling conflicts?
  Suggest an optimal layout for the day.
```

### Daily Priorities
```yaml
name: Daily Priorities
slug: daily-priorities
category: planning
schedule: {at: "08:05"}
priority: 20
system_prompt: |
  You are a strategic planning assistant. Help the user identify
  what matters most today. Be direct and opinionated — don't list
  everything, prioritise ruthlessly.
user_prompt: |
  Based on everything you know about my projects, goals, and recent
  activity, what are the top 3 things I need to be on top of today?
  For each, explain why it matters and what "done" looks like.
  Search my memory for recent context on active projects.
```

### Email Triage
```yaml
name: Email Triage
slug: email-triage
category: email
schedule: {at: "08:10"}
priority: 30
system_prompt: |
  You are an email triage assistant. Scan for unread emails since
  the last check and categorise them:
  - Needs immediate response (with suggested reply outline)
  - Can wait until later today
  - FYI only (no action needed)
  - Can be archived/ignored
  Be ruthless — most emails don't need a reply.
user_prompt: |
  Check my emails since {{last_run}} (or all unread if first run).
  Categorise each one and suggest which need immediate attention.
  For anything that needs a reply, draft a suggested response.
```

### Infrastructure Sweep
```yaml
name: Infrastructure Sweep
slug: infra-sweep
category: infrastructure
schedule: {at: "08:15"}
priority: 40
system_prompt: |
  You are an infrastructure operations analyst. Review the current
  state of all services, deployments, and health checks. Identify:
  - Anything that is down or degraded
  - Approaching capacity limits
  - Pending deployments that need attention
  - Security or maintenance tasks due today
  Be specific — cite service names, metrics, and thresholds.
user_prompt: |
  Do a full infrastructure sweep. Check all services, deployments,
  health checks, database sizes, disk usage, and recent alerts.
  Tell me what needs my attention today and what can wait.
  Search memory for any recent operational incidents or ongoing issues.
```

## Morning Meeting (BriefLive)

### Route

```elixir
live "/briefs", BriefLive, :index
live "/briefs/:slug", BriefLive, :detail
```

### Socket Assigns

```elixir
# Queue
briefs: [%Brief.t()],         # All open briefs, sorted by priority
brief_index: 0,               # Current position in the meeting queue
meeting_active: false,        # Whether the meeting is in progress

# Current brief
current_brief: Brief.t() | nil,
messages: [Brief.Message.t()],  # Conversation thread for current brief

# Discussion
discussion_form: Phoenix.HTML.Form.t(),  # Form for adding discussion messages
pending_response: boolean,               # Waiting for LLM response in discussion

# Stats
stats: %{
  total: 0,
  open: 0,
  reviewed: 0,
  dismissed: 0,
  avg_cost: 0.0
}
```

### UI Flow

```
/briefs
┌─────────────────────────────────────────────────────┐
│  MORNING BRIEF                                      │
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  │
│                                                     │
│  ┌─ STATS BAR ────────────────────────────────────┐ │
│  │ 4 OPEN  │ 12 REVIEWED │ $0.23 TODAY │ 08:32   │ │
│  └────────────────────────────────────────────────┘ │
│                                                     │
│  ┌─ START MEETING ───────────────────────────────┐  │
│  │  [▶ Begin Morning Meeting]                     │  │
│  │  4 briefs ready • estimated ~8 min             │  │
│  └────────────────────────────────────────────────┘  │
│                                                     │
│  ┌─ TODAY'S BRIEFS ──────────────────────────────┐  │
│  │  🔵 Daily Calendar      08:00  ✓ completed    │  │
│  │  🔵 Daily Priorities    08:05  ✓ completed    │  │
│  │  🔵 Email Triage        08:10  ⏳ running     │  │
│  │  🔴 Infrastructure      08:15  ⚑ FAILED       │  │
│  │  │     ▼ provider unreachable: connection     │  │
│  │  │       timeout [↻ Retry]                    │  │
│  └────────────────────────────────────────────────┘  │
│                                                     │
│  ┌─ PAST BRIEFS ─────────────────────────────────┐  │
│  │  Sep 05  Calendar ✓  Priorities ✓  Infra ✓    │  │
│  │  Sep 04  Calendar ✓  Priorities ✓  Email ✓    │  │
│  └────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

### Meeting Mode

When the user clicks "Begin Morning Meeting", the LiveView enters meeting mode:

```
┌─────────────────────────────────────────────────────┐
│  MORNING MEETING  ──  1 of 4  ──  ◀ ●○○○ ▶        │
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  │
│                                                     │
│  ┌─ DAILY CALENDAR CHECK ─────────────────────────┐ │
│  │                                                 │ │
│  │  ## Today's Schedule                            │ │
│  │  - 09:00  Standup (30m)                        │ │
│  │  - 10:00  Design Review — Auth refactor (1h)   │ │
│  │  - 13:00  1:1 with Lenz (30m)                  │ │
│  │  - 14:00  Sprint Planning (1h)                  │ │
│  │                                                 │ │
│  │  ## Key Preparation                             │ │
│  │  - Auth refactor: review PR #142 before meeting │ │
│  │  - Sprint planning: check backlog for B-NNNs   │ │
│  │                                                 │ │
│  │  ## Suggested Focus Blocks                      │ │
│  │  - 09:30–10:00  Review PR #142                 │ │
│  │  - 11:00–13:00  Deep work block                │ │
│  │  - 15:00–17:00  Implementation time            │ │
│  │                                                 │ │
│  │  ## Next Steps                                  │ │
│  │  - [ ] Review PR #142 before 10:00             │ │
│  │  - [ ] Prepare sprint planning notes            │ │
│  └─────────────────────────────────────────────────┘ │
│                                                     │
│  ┌─ DISCUSSION ──────────────────────────────────┐  │
│  │  🤖 The auth refactor review is the critical   │  │
│  │     path item. Want me to pull up PR #142      │  │
│  │     and summarise the changes?                 │  │
│  │                                                 │  │
│  │  👤 Yes, and also check if the test coverage   │  │
│  │     is adequate before the review meeting.     │  │
│  │                                                 │  │
│  │  🤖 Done. PR #142 has 87% coverage on the      │  │
│  │     changed files. Two edge cases in the       │  │
│  │     token refresh flow are uncovered — I've    │  │
│  │     added a note to the PR description.        │  │
│  └─────────────────────────────────────────────────┘ │
│                                                     │
│  ┌─ Add to discussion...                    [Send] │ │
│  └─────────────────────────────────────────────────┘ │
│                                                     │
│  ┌─────────────┐  ┌──────────┐  ┌───────────────┐  │
│  │ ✓ Approve & │  │ ⏭ Skip   │  │ 📋 Edit Steps │  │
│  │   Next      │  │          │  │               │  │
│  └─────────────┘  └──────────┘  └───────────────┘  │
└─────────────────────────────────────────────────────┘
```

### Discussion Flow

When the user types in the discussion box:

1. **Message stored** as a `brief_messages` row with `role: "user"`.
2. **Context built**: full conversation history (system prompt + initial outcome + all discussion messages) sent to the LLM.
3. **LLM response** streamed back, stored as `role: "assistant"`.
4. **LiveView updates** in real-time via PubSub push.

The discussion uses the same LLM proxy, but with a **conversation context** — the initial brief outcome becomes the system context, and the discussion is a multi-turn thread on top.

```elixir
def handle_event("send_discussion", %{"message" => text}, socket) do
  brief = socket.assigns.current_brief

  # Store user message
  {:ok, _} = Brief.add_message(brief, :user, text)

  # Build conversation context
  messages = Brief.full_conversation(brief)

  # Spawn async LLM call
  Task.async(fn ->
    Home.LLMProxy.chat_completion(%{
      "model" => brief.prompt.model || "coder",
      "messages" => messages,
      "temperature" => 0.3,
      "stream" => false
    }, project: "briefs", tool: "brief")
  end)

  {:noreply, assign(socket, :pending_response, true)}
end
```

### Meeting Actions

| Action | Effect |
|--------|--------|
| **Approve & Next** | Sets `reviewed_at`, advances to next brief |
| **Skip** | Advances without reviewing (brief stays open for next meeting) |
| **Edit Steps** | Opens inline editor for `next_steps` / `action_items` |
| **Dismiss** | Marks brief as `dismissed` (won't appear in future meetings) |
| **Retry** | Only shown on `failed` briefs. Re-runs the prompt immediately, linking `retried_from` |
| **Edit Discussion** | Opens the full conversation for continued back-and-forth |

## Parallel Execution Detail

The scheduler fires all due prompts concurrently:

```elixir
defp fire_batch(prompts) do
  tasks =
    Enum.map(prompts, fn prompt ->
      Task.async(fn ->
        # Create a "pending" brief record
        {:ok, brief} = Brief.create(%{
          prompt_id: prompt.id,
          status: "running",
          scheduled_at: DateTime.utc_now()
        })

        case BriefRunner.run(prompt, brief) do
          {:ok, brief} ->
            broadcast({:brief_completed, brief})
            brief

          {:error, reason} ->
            broadcast({:brief_error, brief, reason})
            brief
        end
      end)
    end)

  Task.await_many(tasks, timeout: 120_000)
end
```

`max_concurrency` respects the provider's concurrency limit, capped at 5 — so a fast provider can run all four morning prompts at once, while a rate-limited provider queues safely.

| Setting | Default | Purpose |
|---------|---------|---------|
| `brief_scheduler.max_concurrency` | `5` | Hard cap on parallel prompt executions |

## Provider Integration Points

The prompts need real data sources. Rather than building adapters for each provider, the initial implementation uses **memory search** as the primary data source — the user's existing memories contain calendar notes, email summaries, infrastructure status, and project context.

### Phase 1: Memory-Only

- `user_prompt` templates include "Search my memory for..." instructions.
- The LLM (via the proxy) uses the Recollect memory search to gather context.
- This works today with zero new integrations.

### Phase 2: External Data (future)

| Category | Data Source | Integration |
|----------|------------|-------------|
| Calendar | Google Calendar API | New `Home.External.Calendar` module with OAuth via Cloak secrets |
| Email | IMAP / Gmail API | New `Home.External.Email` module |
| Infrastructure | ops_center MCP | Call `ops-center` tools via existing MCP surface |
| Git | Local repos | Reuse `Home.GitActivity` (already scans `~/code`) |

External data is injected into the `user_prompt` as additional context, not as tool-use loops. This keeps the execution model simple — one LLM call per prompt, no agentic loops.

## Template Variables

| Variable | Resolves To | Example |
|----------|------------|---------|
| `{{date}}` | Current date | `2026-09-06` |
| `{{last_run}}` | ISO timestamp of last completed brief for this prompt | `2026-09-05T08:00:00Z` or `never` |
| `{{yesterday}}` | Previous date | `2026-09-05` |
| `{{weekday}}` | Day name | `Saturday` |

## PubSub Topics

| Topic | Events | Consumers |
|-------|--------|-----------|
| `"briefs"` | `{:briefs_updated, summary}`, `{:brief_completed, brief}`, `{:brief_failed, brief, reason}` | BriefLive, SettingsLive, OverviewLive |
| `"brief:#{id}"` | `{:brief_message, message}`, `{:brief_response_chunk, chunk}` | BriefLive (per-brief subscriptions) |

## Unique Brief Numbers

Every brief execution gets a **deterministic, human-referenceable number** in the running-`BRF`-series, mirroring how backlog tickets use `B-NNN`:

```
BRF-0001   BRF-0002   BRF-0003   ...
```

- **Allocation**: on brief creation, `Brief.allocate_number/0` finds `max(briefs.number)` and emits the next sequential number. Retries also get a fresh number (`BRF-0007` retried from `BRF-0004`), with `retried_from` keeping the lineage.
- **Why**: discussions become referenceable artefacts — notes, next steps, and action items can cite `BRF-0003` in the way `B-1265` is cited today. A later phase makes briefs first-class citizens of the memory system, so the number is the durable key.
- **Uniqueness**: enforced by a unique index on `briefs.number`.
- **Display**: the number is the secondary identifier everywhere the brief is shown (`BRF-0003 · Daily Calendar Check · Today's Schedule`).

## Retention & Memory Integration

**Policy: keep briefs indefinitely.** There is no auto-archive or pruning. The driving goal is that briefs become a structured, browseable history that later phases can surface through the memory system — the same way the ops backlog is a durable, referencable corpus rather than a transient report queue.

### Phase 2: Insights

Because briefs are kept indefinitely, they are a rich source of aggregate signals. `Home.Brief.Insights` (the module, not to be confused with `Home.Memory.Insights`) surfaces both parts of the picture in one place:

- **Execution health** — per prompt: success rate, mean cost, p95 duration, failure reasons (so a flaky provider or a bad prompt template shows up over time).
- **Discussion outcomes** — per category: how many briefs were reviewed vs dismissed, action items generated and closed, recurring themes extracted from `summary` / `next_steps` across weeks.
- **Daily rollups** — for calendar + priorities, a running tally of "days where the top priorities carried over" as a proxy for how well the planning loop is working.

These are computed at query time from the persistent `briefs` rows (no separate rollup table needed while volumes are low), and rendered on `BriefLive` below the queue.

### Phase 3: Memory System

Briefs are written into Recollect alongside the meeting discussion:

1. **On completion** — the `summary` + `outcome` of every brief is stored via `Home.Memory.remember/2` with `scope: "briefs"`, `source: "brief:BRF-0003"`, and `tags: ["brief", category]`. Deduped by the deterministic source_id.
2. **On discussion** — each meeting turn the user actually engages with (a real exchange, not a skim) is remembered under the same scope, tagged `["brief-discussion", category]`.
3. **Searchable** — because they live in Recollect, future prompts and other agents can `Home.Memory.search("what did yesterday's infra sweep flag?", scope: "briefs")` and pick up where the last meeting left off.

Working notes like `docs/backlog/*` stay file-based for humans; the Recollect copy is the machine-facing representation.

## Settings Integration

The `/settings` LiveView gets a new section:

```
┌─ DAILY BRIEF ──────────────────────────────────────┐
│                                                     │
│  Scheduled briefs    [Enabled ▾]                    │
│  Next run            08:00 UTC                      │
│  Today's status      3/4 completed, 1 running       │
│                                                     │
│  [View All Prompts]  [Run Now]  [View History]      │
│                                                     │
└─────────────────────────────────────────────────────┘
```

## Seeding & Management

### Seed File (`priv/repo/seeds.exs`)

```elixir
alias Home.Brief

Brief.create_prompt!(%{
  name: "Daily Calendar Check",
  slug: "daily-calendar",
  category: "calendar",
  system_prompt: "...",
  user_prompt: "...",
  schedule: %{"at" => "08:00"},
  run_weekends: true,
  priority: 10
})

# ... more prompts
```

### Prompt Management UI

A future `/briefs/prompts` management page (or integration into `/settings`) for:
- Creating/editing/deleting prompts
- Toggling enabled/disabled
- Adjusting schedule and priority
- Testing a prompt manually ("Run Now" button)
- Viewing execution history per prompt

## Implementation Plan

### Phase 1: Core (MVP)

1. **Migration** — `brief_prompts`, `briefs`, `brief_messages` tables
2. **Schemas** — `Home.Brief.Prompt`, `Home.Brief.Conversation`, `Home.Brief.Message`
3. **Context** — `Home.Brief` facade with CRUD + lifecycle
4. **Runner** — `Home.Brief.Runner` (LLM proxy call + response parsing)
5. **Scheduler** — `Home.Brief.Scheduler` GenServer (tick + parallel fire)
6. **Seeds** — Default prompts (calendar, priorities, email, infra)
7. **LiveView** — `BriefLive` with queue view + meeting mode
8. **Settings** — Toggle + status in SettingsLive
9. **Cost tracking** — briefs render total/prompt cost in the stats bar and per-brief card

### Phase 2: Discussion & Polish

1. **Multi-turn discussion** — conversation thread in meeting mode
2. **Action items** — editable next steps with status tracking
3. **History view** — past briefs by date
4. **Brief detail view** — deep-dive for individual briefs
5. **Notification** — PubSub push to overview dashboard when briefs complete
6. **Keyboard shortcuts** — arrow keys to navigate, Enter to advance
7. **Brief numbers** — `BRF-XXXX` numbering, cross-referenced in notes and action items
8. **Insights** — `Home.Brief.Insights`: per-prompt execution health + discussion outcome rollups

### Phase 3: External Data + Memory System

1. **Memory system integration** — `summary`/`outcome` written to Recollect under `scope: "briefs"`, tagged per category; discussion turns remembered on user engagement
2. **Calendar adapter** — Google Calendar API integration
3. **Email adapter** — IMAP/Gmail integration
4. **Infrastructure adapter** — ops_center MCP integration
5. **Git context** — auto-inject recent commits per project
6. **Memory enrichment** — pre-brief memory search for each prompt's domain

## Cost Tracking

Brief costs are surfaced **in the app** and flow through the **existing usage tracker** for aggregate reporting:

1. Every LLM call in the runner and discussion is attributed with `project: "briefs"`, `tool: "brief"` — so `/router/projects/briefs` shows cost, calls, and model distribution like every other project on the router dashboard.
2. Per-brief cost is captured on the `briefs.cost_usd` column (or summed from `brief_messages.cost_usd` for discussions).
3. The **stats bar** on `/briefs` shows today's total plus a per-prompt cost in each brief card.
4. The Insights module reports mean cost per prompt over time (part of execution health), so a prompt that starts burning money on a huge context is visible.

## Design Decisions

### Why not Oban?

The scheduling is simple enough for a GenServer tick loop. Oban adds a dependency, requires a running Postgres polling interval, and is overkill for "fire N prompts at 8am." The `ImportScheduler` pattern already works well in this codebase.

### Why not agentic (tool-use loops)?

Each prompt is a single research query → single LLM response. No tool-use loops, no multi-step reasoning. This keeps execution predictable (bounded time, bounded cost) and the outcome structured. If a prompt needs calendar data, it's injected as context, not discovered via tools.

### Why a separate `brief_messages` table instead of embedding in `briefs`?

The discussion during the meeting can be multi-turn. Storing individual messages enables:
- Streaming responses (each chunk appended)
- Conversation history for context continuity
- Cost tracking per message
- Future features like "resume discussion later"

### Why memory-first for data?

The user's Recollect memory already contains project context, operational notes, and imported session data. Starting with memory search means the system works immediately without external API integrations. Each prompt's `user_prompt` instructs the LLM to "search my memory for X" — and the proxy handles it via the existing memory model.

## Resolved Decisions

The earlier open questions are settled as follows:

1. **Cost tracking** — Yes. Briefs attribute to `project: "briefs"` in the usage tracker (shows on `/router/projects/briefs`), per-brief cost on the row, and today's total + per-prompt cost in the `/briefs` stats bar.
2. **Concurrency** — Run at the LLM provider's concurrency limit, hard-capped at 5 (`brief_scheduler.max_concurrency`, default 5). No fixed-4 assumption.
3. **Failure retry** — No auto-retry. The brief is flagged `failed` in the UI with a human-readable reason (e.g. `provider unreachable: connection timeout`) and a manual **Retry** button that re-runs the prompt immediately, linking `retried_from`. A failed run does not block the next day's schedule.
4. **Weekend behaviour** — Configurable per prompt via `run_weekends` (default `false`). `at`-type schedules skip Saturday/Sunday unless enabled.
5. **Retention** — Kept indefinitely. Briefs are durable, referencable artefacts (`BRF-XXXX`) that Phase 3 writes into the memory system (`scope: "briefs"`, tagged by category) so they become searchable history alongside the backlog. No auto-archive.
