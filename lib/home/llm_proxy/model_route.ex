defmodule Home.LLMProxy.ModelRoute do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Home.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "llm_model_routes" do
    field :model_group, :string
    field :provider, :string
    field :model, :string
    field :order, :integer, default: 1
    field :priority, :integer, default: 0
    field :input_cost_per_million, :decimal
    field :output_cost_per_million, :decimal
    field :enabled, :boolean, default: true
    field :notes, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(route, attrs) do
    route
    |> cast(attrs, [
      :model_group,
      :provider,
      :model,
      :order,
      :priority,
      :input_cost_per_million,
      :output_cost_per_million,
      :enabled,
      :notes
    ])
    |> update_change(:model_group, &normalize_text/1)
    |> update_change(:provider, &normalize_text/1)
    |> update_change(:model, &String.trim/1)
    |> validate_required([:model_group, :provider, :model, :order, :priority])
    |> validate_number(:order, greater_than: 0)
    |> unique_constraint([:model_group, :provider, :model])
  end

  def enabled_group_names do
    __MODULE__
    |> where([route], route.enabled == true)
    |> distinct(true)
    |> select([route], route.model_group)
    |> Repo.all()
  end

  def enabled_for_group(model_group) when is_binary(model_group) do
    normalized = normalize_text(model_group)

    __MODULE__
    |> where([route], route.model_group == ^normalized and route.enabled == true)
    |> order_by([route],
      asc: route.order,
      asc: route.priority,
      asc: route.provider,
      asc: route.model
    )
    |> Repo.all()
  end

  def upsert(attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)

    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :order,
           :priority,
           :input_cost_per_million,
           :output_cost_per_million,
           :enabled,
           :notes,
           :updated_at
         ]},
      conflict_target: [:model_group, :provider, :model]
    )
  end

  def delete_group(model_group) when is_binary(model_group) do
    normalized = normalize_text(model_group)
    Repo.delete_all(where(__MODULE__, [route], route.model_group == ^normalized))
  end

  defp normalize_attrs(attrs) do
    attrs
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.update("provider", nil, &to_string/1)
  end

  defp normalize_text(value), do: value |> to_string() |> String.trim() |> String.downcase()
end
