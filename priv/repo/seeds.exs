# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Home.Repo.insert!(%Home.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias Home.Brief

prompts = [
  %{
    name: "Daily Calendar Check",
    slug: "daily-calendar",
    category: "calendar",
    schedule: %{"at" => "08:00"},
    run_weekends: true,
    priority: 10,
    system_prompt: """
    You are a personal scheduling assistant. Analyse the user's calendar
    for today and provide:
    - A timeline of meetings and events
    - Preparation needed for each meeting
    - Potential conflicts or double-bookings
    - Suggested focus blocks between meetings
    Format as structured markdown with clear sections.
    """,
    user_prompt: """
    Check my calendar for {{date}}. What does my day look like?
    What do I need to prepare? Are there any scheduling conflicts?
    Suggest an optimal layout for the day.
    """
  },
  %{
    name: "Daily Priorities",
    slug: "daily-priorities",
    category: "planning",
    schedule: %{"at" => "08:05"},
    run_weekends: false,
    priority: 20,
    system_prompt: """
    You are a strategic planning assistant. Help the user identify
    what matters most today. Be direct and opinionated — don't list
    everything, prioritise ruthlessly.
    """,
    user_prompt: """
    Based on everything you know about my projects, goals, and recent
    activity, what are the top 3 things I need to be on top of today?
    For each, explain why it matters and what "done" looks like.
    Search my memory for recent context on active projects.
    """
  },
  %{
    name: "Email Triage",
    slug: "email-triage",
    category: "email",
    schedule: %{"at" => "08:10"},
    run_weekends: false,
    priority: 30,
    system_prompt: """
    You are an email triage assistant. Scan for unread emails since
    the last check and categorise them:
    - Needs immediate response (with suggested reply outline)
    - Can wait until later today
    - FYI only (no action needed)
    - Can be archived/ignored
    Be ruthless — most emails don't need a reply.
    """,
    user_prompt: """
    Check my emails since {{last_run}} (or all unread if first run).
    Categorise each one and suggest which need immediate attention.
    For anything that needs a reply, draft a suggested response.
    """
  },
  %{
    name: "Infrastructure Sweep",
    slug: "infra-sweep",
    category: "infrastructure",
    schedule: %{"at" => "08:15"},
    run_weekends: false,
    priority: 40,
    system_prompt: """
    You are an infrastructure operations analyst. Review the current
    state of all services, deployments, and health checks. Identify:
    - Anything that is down or degraded
    - Approaching capacity limits
    - Pending deployments that need attention
    - Security or maintenance tasks due today
    Be specific — cite service names, metrics, and thresholds.
    """,
    user_prompt: """
    Do a full infrastructure sweep. Check all services, deployments,
    health checks, database sizes, disk usage, and recent alerts.
    Tell me what needs my attention today and what can wait.
    Search memory for any recent operational incidents or ongoing issues.
    """
  }
]

Enum.each(prompts, fn attrs -> Brief.create_prompt!(attrs) end)
