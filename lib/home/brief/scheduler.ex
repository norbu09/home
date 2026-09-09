defmodule Home.Brief.Scheduler do
  @moduledoc """
  Fires due brief prompts on a one-minute tick loop, gated by the
  `brief_scheduler.enabled` switch in `Home.Settings` (toggled from the
  `/settings` UI).

  Follows the `Home.Memory.ImportScheduler` pattern: initial delay, then a
  self-rescheduling `Process.send_after/3` loop. Due prompts run concurrently
  (capped by `brief_scheduler.max_concurrency`, default 5); failures are
  recorded per-brief and never auto-retried. Events are broadcast on the
  `briefs` PubSub topic.
  """

  use GenServer

  alias Home.Brief
  alias Home.Brief.Runner
  alias Home.Settings

  require Logger

  @topic "briefs"
  @tick_interval :timer.seconds(60)

  defstruct [
    :running_task,
    :last_tick_at,
    :last_fired_at,
    fired_date: nil,
    fired_ids: MapSet.new()
  ]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def topic, do: @topic

  @doc "Fire due prompts now (async), regardless of schedule."
  def fire_now, do: GenServer.cast(__MODULE__, :fire_now)

  @doc "Current scheduler state for the UI."
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(_opts) do
    if enabled?(), do: Process.send_after(self(), :tick, config(:initial_delay_ms, 60_000))
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       running?: not is_nil(state.running_task),
       enabled: enabled?(),
       last_tick_at: state.last_tick_at,
       last_fired_at: state.last_fired_at
     }, state}
  end

  @impl true
  def handle_cast(:fire_now, state) do
    {:noreply, tick(state)}
  end

  @impl true
  def handle_info(:tick, state) do
    state = if enabled?(), do: tick(%{state | last_tick_at: DateTime.utc_now()}), else: state

    # Always reschedule — the switch may be flipped between ticks.
    Process.send_after(self(), :tick, @tick_interval)

    {:noreply, state}
  end

  def handle_info({ref, result}, %{running_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    state = %{state | running_task: nil}

    Phoenix.PubSub.broadcast(Home.PubSub, @topic, {:briefs_batch_finished, result})
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{running_task: %Task{ref: ref}} = state) do
    Logger.warning("brief batch task crashed: #{inspect(reason)}")
    Phoenix.PubSub.broadcast(Home.PubSub, @topic, {:briefs_batch_finished, {:error, reason}})
    {:noreply, %{state | running_task: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @doc false
  def enabled?, do: Settings.get_bool("brief_scheduler.enabled", false)

  @doc """
  Evaluate a single prompt against a point in time. Returns `true` when the
  prompt should fire now given the already-fired ids today.
  """
  def due?(%Brief.Prompt{} = prompt, now, fired_ids) do
    case prompt.schedule do
      %{"at" => time_str} ->
        at? = matches_at?(parse_time(time_str), now)

        at? and not weekend_or_disabled?(prompt, now) and
          not MapSet.member?(fired_ids, prompt.id)

      %{"every_ms" => interval_ms} when is_integer(interval_ms) ->
        true

      _ ->
        false
    end
  end

  defp tick(state) do
    now = DateTime.utc_now()
    today = DateTime.to_date(now)

    fired_ids =
      if state.fired_date == today, do: state.fired_ids, else: MapSet.new()

    due =
      Brief.list_enabled_prompts()
      |> Enum.filter(&due?(&1, now, fired_ids))

    if due == [] or not is_nil(state.running_task) do
      %{state | fired_date: today, fired_ids: fired_ids}
    else
      task = Task.async(fn -> run_batch(due) end)

      %{
        state
        | fired_date: today,
          fired_ids: Enum.reduce(due, fired_ids, &MapSet.put(&2, &1.id)),
          running_task: task,
          last_fired_at: now
      }
    end
  end

  defp run_batch(prompts) do
    prompts
    |> Task.async_stream(&run_prompt/1,
      max_concurrency: concurrency_limit(),
      # Above the agentic backend's 15-min runner timeout, so a long
      # CLI brief isn't killed mid-run with no failure persisted.
      timeout: 16 * 60_000
    )
    |> Enum.to_list()
  end

  defp run_prompt(prompt) do
    {:ok, brief} =
      Brief.create(%{
        prompt_id: prompt.id,
        status: "running",
        scheduled_at: DateTime.utc_now()
      })

    case Runner.run(prompt, brief) do
      {:ok, brief} ->
        Phoenix.PubSub.broadcast(Home.PubSub, @topic, {:brief_completed, brief})
        {:ok, brief}

      {:error, {failed, reason}} ->
        Phoenix.PubSub.broadcast(Home.PubSub, @topic, {:brief_failed, failed, reason})
        {:error, reason}
    end
  end

  defp concurrency_limit do
    otp = config(:max_concurrency, 5)

    if is_integer(otp) and otp > 0,
      do: min(otp, 5),
      else: 5
  end

  defp weekend?(now) do
    now
    |> DateTime.to_date()
    |> Date.day_of_week()
    |> Kernel.in([6, 7])
  end

  defp weekend_or_disabled?(prompt, now) do
    not prompt.run_weekends and weekend?(now)
  end

  defp matches_at?({hour, minute}, %DateTime{hour: hour, minute: minute}), do: true
  defp matches_at?(_time, _now), do: false

  defp parse_time("") do
    nil
  end

  defp parse_time(time_str) do
    case time_str do
      <<hour::binary-size(2), ":", minute::binary-size(2)>> ->
        with {h, ""} <- Integer.parse(hour),
             {m, ""} <- Integer.parse(minute) do
          {h, m}
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp config(key, default) do
    :home
    |> Application.get_env(:brief_scheduler, [])
    |> Keyword.get(key, default)
  end
end
