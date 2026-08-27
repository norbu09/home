defmodule Home.LLMProxy.UsageLog do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Query

  alias Home.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "llm_usage_logs" do
    field :usage_date, :date
    field :project, :string
    field :tool, :string
    field :provider, :string
    field :model, :string
    field :calls, :integer
    field :input_tokens, :integer
    field :output_tokens, :integer
    field :cost_micros, :integer
    field :latency_total_ms, :integer
    field :last_seen_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def insert_snapshots(rows) when is_list(rows) do
    now = DateTime.utc_now()

    entries =
      Enum.map(rows, fn row ->
        row
        |> Map.put(:id, Ecto.UUID.generate())
        |> Map.put(:inserted_at, now)
      end)

    case entries do
      [] -> {0, nil}
      _ -> Repo.insert_all(__MODULE__, entries)
    end
  end

  def since(%Date{} = date) do
    __MODULE__
    |> where([log], log.usage_date >= ^date)
    |> group_by([log], [log.usage_date, log.project, log.tool, log.provider, log.model])
    |> select([log], %{
      usage_date: log.usage_date,
      project: log.project,
      tool: log.tool,
      provider: log.provider,
      model: log.model,
      calls: type(sum(log.calls), :integer),
      input_tokens: type(sum(log.input_tokens), :integer),
      output_tokens: type(sum(log.output_tokens), :integer),
      cost_micros: type(sum(log.cost_micros), :integer),
      latency_total_ms: type(sum(log.latency_total_ms), :integer),
      last_seen_at: max(log.last_seen_at)
    })
    |> Repo.all()
  end

  def recent_batches(limit \\ 100) do
    __MODULE__
    |> order_by([log], desc: log.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end
end
