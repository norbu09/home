defmodule Home.Cognee.InsightTracker do
  @moduledoc "Periodically snapshots Cognee datasets and publishes derived insights."

  use GenServer

  alias Home.Cognee.{Client, DatasetSnapshot, Insights}

  require Logger

  @topic "cognee_insights"

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)
  def refresh, do: GenServer.cast(__MODULE__, :refresh)

  @impl true
  def init(_) do
    previous = safe_previous()
    cached_stats = Enum.map(previous, fn {_id, snapshot} -> Map.from_struct(snapshot) end)

    state = %{
      insights: Insights.build(cached_stats, %{}),
      areas: cached_stats,
      status: if(cached_stats == [], do: :idle, else: :ready),
      updated_at: latest_capture(cached_stats),
      dataset_count: length(cached_stats),
      errors: 0
    }

    if config(:enabled, true),
      do: Process.send_after(self(), :collect, config(:initial_delay_ms, 2_000))

    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast(:refresh, state) do
    send(self(), :collect)
    broadcast_update()
    {:noreply, %{state | status: :syncing}}
  end

  @impl true
  def handle_info(:collect, state) do
    state = collect(state)

    if config(:enabled, true) do
      Process.send_after(self(), :collect, config(:interval_ms, 15 * 60 * 1_000))
    end

    {:noreply, state}
  end

  defp collect(state) do
    previous = safe_previous()

    case Client.fetch_dataset_stats() do
      {:ok, stats, errors} ->
        DatasetSnapshot.record_changes(stats, previous)

        state = %{
          insights: Insights.build(stats, previous),
          areas: stats,
          status: :ready,
          updated_at: DateTime.utc_now(),
          dataset_count: length(stats),
          errors: errors
        }

        broadcast_update()
        state

      {:error, reason} ->
        Logger.warning("Cognee insight collection failed: #{inspect(reason)}")
        broadcast_update()
        %{state | status: :unavailable}
    end
  rescue
    error ->
      Logger.warning("Cognee insight collection crashed: #{Exception.message(error)}")
      broadcast_update()
      %{state | status: :unavailable}
  end

  defp safe_previous do
    DatasetSnapshot.latest_by_dataset()
  rescue
    _error -> %{}
  end

  defp latest_capture([]), do: nil

  defp latest_capture(stats) do
    stats |> Enum.map(& &1.captured_at) |> Enum.max(DateTime, fn -> nil end)
  end

  defp config(key, default) do
    :home
    |> Application.get_env(:cognee_insights, [])
    |> Keyword.get(key, default)
  end

  defp broadcast_update,
    do: Phoenix.PubSub.broadcast(Home.PubSub, @topic, :cognee_insights_updated)
end
