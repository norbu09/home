defmodule Home.Brief.SchedulerTest do
  use Home.DataCase, async: false

  alias Home.Brief.{Prompt, Scheduler}

  defp prompt(overrides) do
    struct!(Prompt, Enum.into(overrides, %{id: Ecto.UUID.generate(), schedule: nil}))
  end

  describe "due?/3" do
    test "at schedule fires when hour/minute match and not yet fired" do
      p = prompt(%{schedule: %{"at" => "08:00"}, run_weekends: true, id: "p1"})
      now = ~U[2026-09-06 08:00:00Z]
      assert Scheduler.due?(p, now, MapSet.new())
      refute Scheduler.due?(p, now, MapSet.new(["p1"]))
    end

    test "at schedule does not fire at other times" do
      p = prompt(%{schedule: %{"at" => "08:00"}, run_weekends: true, id: "p1"})
      now = ~U[2026-09-06 09:00:00Z]
      refute Scheduler.due?(p, now, MapSet.new())
    end

    test "at schedule skips weekends unless run_weekends" do
      saturday = ~U[2026-09-05 08:00:00Z]
      sunday = ~U[2026-09-06 08:00:00Z]

      weekend_skip = prompt(%{schedule: %{"at" => "08:00"}, run_weekends: false, id: "p1"})
      weekend_run = prompt(%{schedule: %{"at" => "08:00"}, run_weekends: true, id: "p2"})

      refute Scheduler.due?(weekend_skip, saturday, MapSet.new())
      assert Scheduler.due?(weekend_run, saturday, MapSet.new())
      refute Scheduler.due?(weekend_skip, sunday, MapSet.new())
      assert Scheduler.due?(weekend_run, sunday, MapSet.new())
    end

    test "every_ms schedule fires on a fresh day" do
      p = prompt(%{schedule: %{"every_ms" => 86_400_000}, run_weekends: true, id: "p1"})
      now = ~U[2026-09-06 08:00:00Z]
      assert Scheduler.due?(p, now, MapSet.new())
    end
  end

  test "init/1 starts with a clean fired state" do
    assert {:ok, %Scheduler{fired_ids: ids, running_task: nil}} = Scheduler.init([])
    assert Enum.empty?(ids)
  end

  test "status/0 reports when the scheduler has not fired" do
    assert %{running?: false, enabled: false} = Scheduler.status()
  end
end
