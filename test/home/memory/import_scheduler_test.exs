defmodule Home.Memory.ImportSchedulerTest do
  use Home.DataCase, async: false

  alias Home.Memory.ImportScheduler
  alias Home.Settings

  test "initial state can accept the task created by a scheduled import" do
    {:ok, _} = Settings.put_bool("memory_import.enabled", false)

    assert {:ok, %{running?: false, task: nil}} = ImportScheduler.init([])
  end
end
