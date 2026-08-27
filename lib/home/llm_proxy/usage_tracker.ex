defmodule Home.LLMProxy.UsageTracker do
  @moduledoc """
  LLM usage, cost, and project policy tracking.

  Completed calls are aggregated in ETS and periodically appended to the database.
  Snapshots merge persisted history with the unflushed ETS delta. Provider-reported
  cost is preferred; otherwise cost is estimated from the configured model price
  table. No provider usage APIs are polled by this process.
  """

  use GenServer

  alias Home.LLMProxy.{ModelRouting, ProviderCatalog, UsageLog}

  require Logger

  @usage_table :home_llm_usage
  @policy_table :home_llm_project_policies
  @topic "llm_usage"

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def record(attrs) when is_map(attrs), do: GenServer.call(__MODULE__, {:record, attrs})

  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  def project_details(project) when is_binary(project) do
    GenServer.call(__MODULE__, {:project_details, project})
  end

  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  def flush do
    GenServer.call(__MODULE__, :flush, 30_000)
  end

  def set_project_policy(project, attrs) when is_binary(project) and is_map(attrs) do
    GenServer.call(__MODULE__, {:set_policy, project, attrs})
  end

  def project_allowed?(project) do
    policy(project).enabled
  end

  def apply_project_policy(chain, project, kind \\ :chat) when is_list(chain) do
    project_policy = policy(project)

    chain =
      if kind == :chat and present?(Map.get(project_policy, :default_model, "")) do
        ModelRouting.resolve_chain(Map.get(project_policy, :default_model), :chat)
      else
        chain
      end

    case project_policy do
      %{routing_mode: "pinned", provider: provider} when is_binary(provider) and provider != "" ->
        pinned_chain(provider, chain)

      _ ->
        chain
    end
  end

  def policy(project) do
    project = normalize_project(project)

    case safe_lookup(@policy_table, project) do
      %{policy: policy} -> policy
      _ -> default_policy(project)
    end
  end

  def cost_for(model, input_tokens, output_tokens) do
    prices = Application.get_env(:home, :llm_model_prices, %{})

    case lookup_price(prices, to_string(model || "")) do
      %{input: input_price, output: output_price} ->
        input_tokens / 1_000_000 * input_price + output_tokens / 1_000_000 * output_price

      _ ->
        0.0
    end
  end

  @impl true
  def init(_) do
    :ets.new(@usage_table, [:named_table, :set, :protected, read_concurrency: true])
    :ets.new(@policy_table, [:named_table, :set, :protected, read_concurrency: true])
    seed_policies()
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:record, attrs}, _from, state) do
    now = DateTime.utc_now()
    project = normalize_project(attrs[:project])
    tool = normalize_tool(attrs[:tool])
    provider = to_string(attrs[:provider] || "unknown")
    model = to_string(attrs[:model] || "unknown")
    input = non_negative_integer(attrs[:input_tokens])
    output = non_negative_integer(attrs[:output_tokens])
    latency = non_negative_integer(attrs[:latency_ms])
    cost = normalized_cost(attrs[:cost_usd], model, input, output)

    update_usage(
      DateTime.to_date(now),
      project,
      tool,
      provider,
      model,
      input,
      output,
      cost,
      latency,
      now
    )

    ensure_policy(project)
    broadcast_update()
    {:reply, :ok, state}
  end

  def handle_call({:set_policy, project, attrs}, _from, state) do
    current = policy(project)

    updated =
      Map.merge(current, %{
        enabled: Map.get(attrs, :enabled, current.enabled),
        routing_mode: Map.get(attrs, :routing_mode, current.routing_mode),
        provider: Map.get(attrs, :provider, current.provider),
        default_model: Map.get(attrs, :default_model, Map.get(current, :default_model, "")),
        quota_usd: Map.get(attrs, :quota_usd, current.quota_usd),
        name: Map.get(attrs, :name, current.name)
      })

    :ets.insert(@policy_table, {project, %{policy: updated}})
    broadcast_update()
    {:reply, {:ok, updated}, state}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, build_snapshot(), state}
  end

  def handle_call({:project_details, project}, _from, state) do
    {:reply, build_project_details(normalize_project(project)), state}
  end

  def handle_call(:flush, _from, state) do
    {:reply, flush_usage(), state}
  end

  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@usage_table)
    :ets.delete_all_objects(@policy_table)
    seed_policies()
    broadcast_update()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    case flush_usage() do
      {:ok, _count} -> :ok
      {:error, reason} -> Logger.warning("LLM usage sweep failed: #{inspect(reason)}")
    end

    schedule_sweep()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    case flush_usage() do
      {:ok, _count} -> :ok
      {:error, reason} -> Logger.warning("LLM usage termination flush failed: #{inspect(reason)}")
    end

    :ok
  end

  defp update_usage(usage_date, project, tool, provider, model, input, output, cost, latency, now) do
    key = {usage_date, project, tool, provider, model}

    current =
      case :ets.lookup(@usage_table, key) do
        [{^key, aggregate}] -> aggregate
        _ -> empty_aggregate(project, tool, provider, model)
      end

    aggregate = %{
      current
      | calls: current.calls + 1,
        input_tokens: current.input_tokens + input,
        output_tokens: current.output_tokens + output,
        cost_micros: current.cost_micros + round(cost * 1_000_000),
        latency_total_ms: current.latency_total_ms + latency,
        last_seen_at: now
    }

    :ets.insert(@usage_table, {key, aggregate})
  end

  defp empty_aggregate(project, tool, provider, model) do
    %{
      project: project,
      tool: tool,
      provider: provider,
      model: model,
      calls: 0,
      input_tokens: 0,
      output_tokens: 0,
      cost_micros: 0,
      latency_total_ms: 0,
      last_seen_at: nil
    }
  end

  defp build_snapshot do
    now = DateTime.utc_now()
    today = DateTime.to_date(now)
    month_start = Date.beginning_of_month(today)
    rows = persisted_usage_since(month_start) ++ pending_usage_since(month_start)
    monthly = rows
    daily = Enum.filter(rows, &(&1.usage_date == today))
    policies = policies()

    %{
      month: summarize(monthly),
      today: summarize(daily),
      projects: project_snapshots(monthly, policies),
      tools: tool_snapshots(monthly, true),
      providers: provider_snapshots(monthly),
      updated_at: now
    }
  end

  defp build_project_details(project) do
    now = DateTime.utc_now()
    today = DateTime.to_date(now)
    month_start = Date.beginning_of_month(today)

    rows =
      (persisted_usage_since(month_start) ++ pending_usage_since(month_start))
      |> Enum.filter(&(&1.project == project))

    %{
      project: project,
      policy: policy(project),
      month: summarize(rows),
      today: rows |> Enum.filter(&(&1.usage_date == today)) |> summarize(),
      providers: provider_snapshots(rows),
      models: model_snapshots(rows),
      tools: tool_snapshots(rows, project == "tools"),
      daily: daily_snapshots(rows),
      last_seen_at: latest_seen(rows),
      updated_at: now
    }
  end

  defp pending_usage_since(date) do
    @usage_table
    |> :ets.tab2list()
    |> Enum.flat_map(fn
      {{usage_date, _project, _tool, _provider, _model}, aggregate} when usage_date >= date ->
        [Map.put(aggregate, :usage_date, usage_date)]

      _ ->
        []
    end)
  end

  defp persisted_usage_since(date) do
    UsageLog.since(date)
  rescue
    error ->
      Logger.warning("LLM usage history read failed: #{Exception.message(error)}")
      []
  end

  defp summarize(rows) do
    Enum.reduce(rows, empty_summary(), fn row, acc ->
      calls = integer_value(row.calls)
      input_tokens = integer_value(row.input_tokens)
      output_tokens = integer_value(row.output_tokens)
      cost_micros = integer_value(row.cost_micros)

      %{
        calls: acc.calls + calls,
        input_tokens: acc.input_tokens + input_tokens,
        output_tokens: acc.output_tokens + output_tokens,
        cost_usd: acc.cost_usd + cost_micros / 1_000_000
      }
    end)
  end

  defp empty_summary, do: %{calls: 0, input_tokens: 0, output_tokens: 0, cost_usd: 0.0}

  defp project_snapshots(rows, policies) do
    usage_by_project = Enum.group_by(rows, & &1.project)
    project_names = Map.keys(usage_by_project) |> Kernel.++(Map.keys(policies)) |> Enum.uniq()

    project_names
    |> Enum.map(fn project ->
      usage = summarize(Map.get(usage_by_project, project, []))
      policy = Map.get(policies, project, default_policy(project))
      last_seen = latest_seen(Map.get(usage_by_project, project, []))

      Map.merge(usage, policy)
      |> Map.merge(%{id: project, project: project, last_seen_at: last_seen})
    end)
    |> Enum.sort_by(& &1.cost_usd, :desc)
  end

  defp provider_snapshots(rows) do
    rows
    |> Enum.group_by(& &1.provider)
    |> Enum.map(fn {provider, provider_rows} ->
      summary = summarize(provider_rows)
      latency_total = Enum.sum(Enum.map(provider_rows, &integer_value(&1.latency_total_ms)))

      Map.merge(summary, %{
        provider: provider,
        latency_ms: if(summary.calls > 0, do: div(latency_total, summary.calls), else: nil),
        last_seen_at: latest_seen(provider_rows)
      })
    end)
    |> Enum.sort_by(& &1.cost_usd, :desc)
  end

  defp model_snapshots(rows) do
    rows
    |> Enum.group_by(& &1.model)
    |> Enum.map(fn {model, model_rows} ->
      summary = summarize(model_rows)
      latency_total = Enum.sum(Enum.map(model_rows, &integer_value(&1.latency_total_ms)))

      Map.merge(summary, %{
        id: model,
        model: model,
        providers: model_rows |> Enum.map(& &1.provider) |> Enum.uniq() |> Enum.sort(),
        latency_ms: if(summary.calls > 0, do: div(latency_total, summary.calls), else: nil),
        last_seen_at: latest_seen(model_rows)
      })
    end)
    |> Enum.sort_by(& &1.cost_usd, :desc)
  end

  defp daily_snapshots(rows) do
    rows
    |> Enum.group_by(& &1.usage_date)
    |> Enum.map(fn {date, date_rows} -> Map.put(summarize(date_rows), :date, date) end)
    |> Enum.sort_by(& &1.date)
  end

  defp tool_snapshots(rows, include_config) do
    tool_config = Application.get_env(:home, :llm_tools, %{})

    usage_by_tool =
      rows
      |> Enum.reject(&(is_nil(&1.tool) || &1.tool == ""))
      |> Enum.group_by(& &1.tool)

    tool_ids =
      if include_config do
        usage_by_tool |> Map.keys() |> Kernel.++(Map.keys(tool_config)) |> Enum.uniq()
      else
        Map.keys(usage_by_tool)
      end

    tool_ids
    |> Enum.map(fn tool ->
      tool_rows = Map.get(usage_by_tool, tool, [])
      summary = summarize(tool_rows)
      attrs = Map.get(tool_config, tool, %{})
      latency_total = Enum.sum(Enum.map(tool_rows, &integer_value(&1.latency_total_ms)))
      provider_count = tool_rows |> Enum.map(& &1.provider) |> Enum.uniq() |> length()
      models = tool_rows |> Enum.map(& &1.model) |> Enum.uniq() |> Enum.sort()

      Map.merge(summary, %{
        id: tool,
        tool: tool,
        name: Map.get(attrs, :name, default_tool_name(tool)),
        category: Map.get(attrs, :category, "background"),
        provider_count: provider_count,
        model_count: length(models),
        models: models,
        latency_ms: if(summary.calls > 0, do: div(latency_total, summary.calls), else: nil),
        last_seen_at: latest_seen(tool_rows)
      })
    end)
    |> Enum.sort_by(fn tool -> {-tool.calls, tool.name} end)
  end

  defp latest_seen(rows) do
    rows
    |> Enum.map(& &1.last_seen_at)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp integer_value(%Decimal{} = value), do: Decimal.to_integer(value)
  defp integer_value(value) when is_integer(value), do: value
  defp integer_value(nil), do: 0

  defp flush_usage do
    rows =
      @usage_table
      |> :ets.tab2list()
      |> Enum.map(fn {{usage_date, _project, _tool, _provider, _model}, aggregate} ->
        aggregate
        |> Map.put(:usage_date, usage_date)
        |> Map.take([
          :usage_date,
          :project,
          :tool,
          :provider,
          :model,
          :calls,
          :input_tokens,
          :output_tokens,
          :cost_micros,
          :latency_total_ms,
          :last_seen_at
        ])
      end)

    case UsageLog.insert_snapshots(rows) do
      {count, _} ->
        :ets.delete_all_objects(@usage_table)
        broadcast_update()
        {:ok, count}
    end
  rescue
    error -> {:error, error}
  end

  defp schedule_sweep do
    interval = Application.get_env(:home, :llm_usage_sweep_interval_ms, 60_000)
    Process.send_after(self(), :sweep, interval)
  end

  defp policies do
    @policy_table
    |> :ets.tab2list()
    |> Map.new(fn {project, %{policy: policy}} -> {project, policy} end)
  end

  defp seed_policies do
    :home
    |> Application.get_env(:llm_projects, %{})
    |> Enum.each(fn {project, attrs} ->
      project = normalize_project(project)
      policy = Map.merge(default_policy(project), Map.new(attrs))
      :ets.insert(@policy_table, {project, %{policy: policy}})
    end)
  end

  defp ensure_policy(project) do
    if :ets.lookup(@policy_table, project) == [] do
      :ets.insert(@policy_table, {project, %{policy: default_policy(project)}})
    end
  end

  defp default_policy(project) do
    %{
      name:
        project
        |> String.replace("_", " ")
        |> String.split()
        |> Enum.map_join(" ", &String.capitalize/1),
      enabled: true,
      routing_mode: "automatic",
      provider: "",
      default_model: "",
      quota_usd: 0.0
    }
  end

  defp pinned_chain(provider, chain) do
    with {:ok, provider_atom} <- provider_atom(provider),
         [] <- Enum.filter(chain, &(elem(&1, 0) == provider_atom)),
         {:ok, module} <- ProviderCatalog.fetch(provider_atom),
         [%{id: model_id} | _] <- module.default_models() do
      [{provider_atom, model_id}]
    else
      [_ | _] = routes -> routes
      _ -> chain
    end
  end

  defp provider_atom(provider) do
    atom = String.to_existing_atom(provider)
    if atom in ProviderCatalog.names(), do: {:ok, atom}, else: :error
  rescue
    ArgumentError -> :error
  end

  defp normalized_cost(cost, _model, _input, _output) when is_number(cost), do: cost * 1.0
  defp normalized_cost(_cost, model, input, output), do: cost_for(model, input, output)

  defp lookup_price(prices, model) do
    bare = model |> String.split("/") |> List.last()

    Map.get(prices, model) || Map.get(prices, bare) || longest_prefix_price(prices, model, bare)
  end

  defp longest_prefix_price(prices, model, bare) do
    prices
    |> Enum.filter(fn {key, _price} ->
      String.starts_with?(model, key) || String.starts_with?(bare, key)
    end)
    |> Enum.max_by(fn {key, _price} -> String.length(key) end, fn -> nil end)
    |> case do
      {_key, price} -> price
      nil -> nil
    end
  end

  defp normalize_project(nil), do: "unattributed"
  defp normalize_project(""), do: "unattributed"

  defp normalize_project(project),
    do: project |> to_string() |> String.trim() |> String.downcase()

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp normalize_tool(nil), do: nil
  defp normalize_tool(""), do: nil

  defp normalize_tool(tool) do
    case tool |> to_string() |> String.trim() |> String.downcase() do
      "" -> nil
      tool -> tool
    end
  end

  defp default_tool_name(tool) do
    tool
    |> String.replace("_", " ")
    |> String.replace("-", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: 0

  defp safe_lookup(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> value
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp broadcast_update do
    Phoenix.PubSub.broadcast(Home.PubSub, @topic, :llm_usage_updated)
  rescue
    ArgumentError -> :ok
  end
end
