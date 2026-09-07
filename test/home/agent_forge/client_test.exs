defmodule Home.AgentForge.ClientTest do
  use Home.DataCase, async: false

  alias Home.AgentForge.Client

  # Fake transport backed by an Agent holding the next run state to return
  # from `run_status/1` plus what `enqueue/1` last returned.
  defmodule FakeTransport do
    @moduledoc false
    def start(enqueue_result, statuses) do
      Agent.start_link(fn -> %{enqueue: enqueue_result, statuses: statuses, enqueued: []} end,
        name: __MODULE__
      )
    end

    def stop, do: Agent.stop(__MODULE__)

    def enqueue(meta) do
      Agent.get_and_update(__MODULE__, fn s ->
        {s.enqueue, %{s | enqueued: [meta | s.enqueued]}}
      end)
    end

    def run_status(job_id) do
      Agent.get_and_update(__MODULE__, fn s ->
        case s.statuses do
          [] ->
            {{:error, {:run_not_found, %{}}}, s}

          [current | rest] ->
            {{:ok,
              %{"status" => current.status, "outcome" => current.outcome, "run_id" => job_id}},
             %{s | statuses: rest}}
        end
      end)
    end

    def enqueued_args do
      Agent.get(__MODULE__, & &1.enqueued)
    end
  end

  setup do
    old = Application.get_env(:home, :agent_forge, [])

    Application.put_env(:home, :agent_forge,
      transport: FakeTransport,
      enabled: true,
      project: "ops_center",
      poll_interval_ms: 10,
      poll_timeout_ms: 500
    )

    on_exit(fn ->
      Application.put_env(:home, :agent_forge, old)
      System.delete_env("AGENT_FORGE_WEBHOOK_TOKEN")
      if Process.whereis(FakeTransport), do: FakeTransport.stop()
    end)

    System.put_env("AGENT_FORGE_WEBHOOK_TOKEN", "test-token")
    :ok
  end

  describe "fleet_sweep_report/1" do
    test "returns the agent's report on a completed run" do
      FakeTransport.start({:ok, "job_1"}, [
        %{status: "completed", outcome: "## Summary\nAll green\n\n- [ ] water backups"}
      ])

      {:ok, res} = Client.fleet_sweep_report(source_id: "brief:test-1")
      assert res.job_id == "job_1"
      assert res.report =~ "All green"
    end

    test "polls running -> completed and returns the report" do
      FakeTransport.start({:ok, "job_7"}, [
        %{status: "running", outcome: nil},
        %{status: "completed", outcome: "## Summary\nConverged"}
      ])

      {:ok, res} = Client.fleet_sweep_report(source_id: "brief:test-2")
      assert res.report =~ "Converged"
    end

    test "returns an error when the run fails" do
      FakeTransport.start({:ok, "job_2"}, [%{status: "failed", outcome: nil}])

      assert {:error, {:run_failed, "job_2", _}} =
               Client.fleet_sweep_report(source_id: "brief:test-3")
    end

    test "returns an error when the run is cancelled" do
      FakeTransport.start({:ok, "job_3"}, [%{status: "cancelled", outcome: nil}])

      assert {:error, {:run_cancelled, "job_3", _}} =
               Client.fleet_sweep_report(source_id: "brief:test-4")
    end

    test "times out when the run never reaches a terminal state" do
      # run_status returns run_not_found forever until the deadline.
      FakeTransport.start({:ok, "job_4"}, [])

      assert {:error, {:poll_timeout, "job_4"}} =
               Client.fleet_sweep_report(source_id: "brief:test-5")
    end

    test "errors when disabled" do
      Application.put_env(:home, :agent_forge, transport: FakeTransport, enabled: false)

      assert {:error, :disabled} = Client.fleet_sweep_report(source_id: "brief:test-6")
    end

    test "enqueues the goal to the configured project" do
      FakeTransport.start({:ok, "job_9"}, [%{status: "completed", outcome: "ok"}])

      Client.fleet_sweep_report(goal: "sweep now", source_id: "brief:flag")
      [args] = FakeTransport.enqueued_args()

      assert args.project == "ops_center"
      assert args.goal == "sweep now"
      assert args.source_id == "brief:flag"
    end
  end
end
