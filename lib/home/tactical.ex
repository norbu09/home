defmodule Home.Tactical do
  @moduledoc "Local tactical status items used by the Home overview."

  import Ecto.Query

  alias Home.Repo
  alias Home.Tactical.Item

  def list_goals do
    Item
    |> where([item], item.kind == "goal" and item.status in ["active", "completed"])
    |> order_by([item],
      asc: item.status,
      asc: item.priority,
      asc: item.due_on,
      desc: item.inserted_at
    )
    |> Repo.all()
  end

  def list_upcoming_meetings do
    now = DateTime.utc_now()

    Item
    |> where([item], item.kind == "meeting" and item.status == "active")
    |> where([item], is_nil(item.starts_at) or item.starts_at >= ^now)
    |> order_by([item], asc: item.starts_at, asc: item.priority)
    |> limit(8)
    |> Repo.all()
  end

  def list_insights do
    Item
    |> where([item], item.kind == "insight" and item.status == "active")
    |> order_by([item], asc: item.priority, desc: item.inserted_at)
    |> limit(8)
    |> Repo.all()
  end

  def create_item(attrs), do: %Item{} |> Item.changeset(attrs) |> Repo.insert()

  def toggle_goal(id) do
    with %Item{kind: "goal"} = item <- Repo.get(Item, id) do
      status = if item.status == "completed", do: "active", else: "completed"
      item |> Item.changeset(%{status: status}) |> Repo.update()
    else
      _ -> {:error, :not_found}
    end
  end

  def dismiss(id) do
    case Repo.get(Item, id) do
      nil -> {:error, :not_found}
      item -> item |> Item.changeset(%{status: "dismissed"}) |> Repo.update()
    end
  end
end
