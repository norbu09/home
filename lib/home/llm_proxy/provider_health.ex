defmodule Home.LLMProxy.ProviderHealth do
  @moduledoc """
  Cross-client provider health for the local LLM proxy.

  This is a local, in-memory adaptation of kfos_agent's provider health layer:
  hard failures temporarily remove a provider from routing and recent failures
  demote it behind healthier alternatives.
  """

  use GenServer

  @table :home_llm_proxy_provider_health
  @hard_lock_ms 10 * 60 * 1000
  @soft_demote_ms 2 * 60 * 1000

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def report_success(provider, tokens \\ 0, latency_ms \\ nil)

  def report_success({provider, model}, tokens, latency_ms) do
    GenServer.cast(__MODULE__, {:success, route_key(provider, model), tokens, latency_ms})
    GenServer.cast(__MODULE__, {:success, provider_key(provider), tokens, latency_ms})
  end

  def report_success(provider, tokens, latency_ms) do
    GenServer.cast(__MODULE__, {:success, provider_key(provider), tokens, latency_ms})
  end

  def report_error(provider, classification, retry_after_ms \\ nil)

  def report_error({provider, model}, classification, retry_after_ms) do
    GenServer.cast(
      __MODULE__,
      {:error, route_key(provider, model), classification, retry_after_ms}
    )
  end

  def report_error(provider, classification, retry_after_ms) do
    GenServer.cast(__MODULE__, {:error, provider_key(provider), classification, retry_after_ms})
  end

  def reset do
    if :ets.whereis(@table) != :undefined do
      :ets.delete_all_objects(@table)
    end

    :ok
  end

  def snapshot do
    if :ets.whereis(@table) == :undefined do
      %{}
    else
      @table |> :ets.tab2list() |> Map.new()
    end
  end

  def order_chain(chain) do
    now = System.system_time(:millisecond)

    chain
    |> Enum.reject(fn {provider, model} ->
      locked?(provider_key(provider), now) or locked?(route_key(provider, model), now)
    end)
    |> Enum.sort_by(fn {provider, _model} -> demote_score(to_string(provider), now) end)
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:success, provider, tokens, latency_ms}, state) do
    :ets.insert(@table, {
      provider,
      %{last_success: now(), tokens: tokens, latency_ms: latency_ms, locked_until: nil}
    })

    {:noreply, state}
  end

  def handle_cast({:error, provider, classification, retry_after_ms}, state) do
    now = now()
    lock_ms = retry_after_ms || lock_ms(classification)

    :ets.insert(@table, {
      provider,
      %{
        last_error: now,
        classification: classification,
        locked_until: if(lock_ms > 0, do: now + lock_ms)
      }
    })

    {:noreply, state}
  end

  defp locked?(provider, now) do
    case lookup(provider) do
      %{locked_until: until_ms} when is_integer(until_ms) -> until_ms > now
      _ -> false
    end
  end

  defp demote_score(provider, now) do
    case lookup(provider) do
      %{last_error: last_error}
      when is_integer(last_error) and now - last_error < @soft_demote_ms ->
        1

      _ ->
        0
    end
  end

  defp lookup(provider) do
    case :ets.lookup(@table, provider) do
      [{^provider, state}] -> state
      _ -> %{}
    end
  rescue
    ArgumentError -> %{}
  end

  defp lock_ms(classification) when classification in [:rate_limit, :overloaded, :timeout],
    do: @soft_demote_ms

  defp lock_ms(:context_overflow), do: 0
  defp lock_ms(_), do: @hard_lock_ms

  defp now, do: System.system_time(:millisecond)

  defp provider_key(provider), do: to_string(provider)
  defp route_key(provider, model), do: "#{provider_key(provider)}/#{model}"
end
