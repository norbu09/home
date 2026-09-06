defmodule Home.Brief.Insights do
  @moduledoc """
  Per-prompt execution health rollups: success rate, failure rate,
  average cost, and the last completed brief. Used by the BriefLive
  health panel and the Overview dashboard.
  """

  import Ecto.Query

  alias Home.Brief.Conversation
  alias Home.Brief.Prompt
  alias Home.Repo

  @doc "Per-prompt health over the last 30 days. Returns a list sorted by prompt name."
  def by_prompt do
    cutoff = DateTime.add(DateTime.utc_now(), -30, :day)

    Prompt
    |> join(:inner, [p], c in Conversation, on: c.prompt_id == p.id)
    |> where([_p, c], c.inserted_at >= ^cutoff)
    |> group_by([p, c], [p.id, p.name, p.slug])
    |> select([p, c], %{
      prompt: p,
      runs: count(c.id),
      completed: fragment("count(*) filter (where ? in ('completed', 'reviewed'))", c.status),
      failed: fragment("count(*) filter (where ? = 'failed')", c.status),
      avg_cost_usd: avg(c.cost_usd),
      last_completed_at: max(c.completed_at)
    })
    |> order_by([p], asc: p.name)
    |> Repo.all()
  end
end
