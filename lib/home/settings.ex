defmodule Home.Settings do
  @moduledoc """
  Tiny durable key/value store for app-wide toggles and bookkeeping
  (e.g. the memory import switch and its last-run summary).

  Values are stored as plain strings; `get_bool/2` / `put_bool/2` cover the
  common toggle case.
  """

  use Ecto.Schema

  import Ecto.Query

  alias Home.Repo

  @primary_key {:key, :string, []}
  schema "home_settings" do
    field :value, :string

    timestamps(type: :utc_datetime_usec)
  end

  @table __MODULE__

  @doc "Get a setting's raw string value, or `default`."
  def get(key, default \\ nil) do
    case Repo.get(@table, key) do
      nil -> default
      %{value: value} -> value
    end
  end

  @doc "Upsert a setting."
  def put(key, value) when is_binary(key) and is_binary(value) do
    %@table{key: key}
    |> Ecto.Changeset.change(value: value)
    |> Repo.insert(
      on_conflict: [set: [value: value, updated_at: DateTime.utc_now()]],
      conflict_target: :key
    )
  end

  @doc "Boolean view of a setting (\"true\" is true; anything else false)."
  def get_bool(key, default \\ false) do
    case get(key) do
      nil -> default
      "true" -> true
      _ -> false
    end
  end

  @doc "Store a boolean setting."
  def put_bool(key, value) when is_boolean(value), do: put(key, to_string(value))

  @doc "Store a JSON-encodable setting."
  def put_json(key, value) do
    with {:ok, json} <- Jason.encode(value) do
      put(key, json)
    end
  end

  @doc "Decode a JSON setting, or `default` when unset/invalid."
  def get_json(key, default \\ nil) do
    case get(key) do
      nil ->
        default

      json ->
        case Jason.decode(json) do
          {:ok, value} -> value
          {:error, _} -> default
        end
    end
  end

  @doc "All settings as a map."
  def all do
    @table
    |> select([s], {s.key, s.value})
    |> Repo.all()
    |> Map.new()
  end
end
