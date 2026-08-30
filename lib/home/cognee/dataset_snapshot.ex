defmodule Home.Cognee.DatasetSnapshot do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Home.Repo

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "cognee_dataset_snapshots" do
    field :dataset_id, :string
    field :dataset_name, :string
    field :item_count, :integer
    field :recent_day_count, :integer
    field :recent_week_count, :integer
    field :latest_activity_at, :utc_datetime_usec
    field :captured_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :dataset_id,
      :dataset_name,
      :item_count,
      :recent_day_count,
      :recent_week_count,
      :latest_activity_at,
      :captured_at
    ])
    |> validate_required([:dataset_id, :dataset_name, :item_count, :captured_at])
  end

  def latest_by_dataset do
    __MODULE__
    |> distinct([snapshot], snapshot.dataset_id)
    |> order_by([snapshot], asc: snapshot.dataset_id, desc: snapshot.captured_at)
    |> Repo.all()
    |> Map.new(&{&1.dataset_id, &1})
  end

  def record_changes(stats, previous) do
    Enum.each(stats, fn stat ->
      if snapshot_changed?(stat, Map.get(previous, stat.dataset_id)) do
        %__MODULE__{}
        |> changeset(stat)
        |> Repo.insert()
      end
    end)
  end

  defp snapshot_changed?(_stat, nil), do: true

  defp snapshot_changed?(stat, previous) do
    stat.item_count != previous.item_count or
      activity_changed?(stat.latest_activity_at, previous.latest_activity_at)
  end

  defp activity_changed?(nil, nil), do: false

  defp activity_changed?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) != :eq

  defp activity_changed?(_left, _right), do: true
end
