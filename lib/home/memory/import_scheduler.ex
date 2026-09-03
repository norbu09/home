defmodule Home.Memory.ImportScheduler do
  @moduledoc """
  Runs the memory import (`Home.Memory.Importer`) on a regular cadence,
  gated by the `memory_import.enabled` switch in `Home.Settings` (toggled
  from the `/memory` UI).

  Pattern: initial delay, then a self-rescheduling `Process.send_after/3`
  loop. Results are broadcast on the `memory_import` PubSub topic so the
  LiveView updates live.
  """

  use GenServer

  alias Home.Memory.Importer
  alias Home.Settings

  require Logger

  @topic "memory_import"

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def topic, do: @topic

  def enabled?, do: Settings.get_bool("memory_import.enabled", false)

  @doc "Kick off an import right now (async), regardless of the schedule."
  def import_now, do: GenServer.cast(__MODULE__, :import_now)

  @doc "Current scheduler state for the UI."
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(_opts) do
    if enabled?(), do: Process.send_after(self(), :tick, config(:initial_delay_ms, 60_000))

    {:ok, %{running?: false, last_result: nil, last_run_at: nil}}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast(:import_now, %{running?: true} = state), do: {:noreply, state}

  def handle_cast(:import_now, state) do
    {:noreply, run_import(state)}
  end

  @impl true
  def handle_info(:tick, state) do
    state =
      if enabled?() do
        run_import(state)
      else
        state
      end

    # Always reschedule — the switch may be flipped between ticks.
    Process.send_after(self(), :tick, config(:interval_ms, :timer.hours(24)))

    {:noreply, state}
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    state = %{
      state
      | running?: false,
        task: nil,
        last_result: result,
        last_run_at: DateTime.utc_now()
    }

    Phoenix.PubSub.broadcast(Home.PubSub, @topic, {:memory_import_finished, result})

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.warning("memory import task crashed: #{inspect(reason)}")

    state = %{state | running?: false, task: nil}
    Phoenix.PubSub.broadcast(Home.PubSub, @topic, :memory_import_failed)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp run_import(state) do
    task = Task.async(fn -> Importer.run() end)
    broadcast_started()

    %{state | running?: true, task: task}
  end

  defp broadcast_started do
    Phoenix.PubSub.broadcast(Home.PubSub, @topic, :memory_import_started)
  end

  defp config(key, default) do
    :home
    |> Application.get_env(:memory_import, [])
    |> Keyword.get(key, default)
  end
end
