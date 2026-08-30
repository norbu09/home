defmodule HomeWeb.ProjectLive do
  @moduledoc "Per-project LLM usage and routing controls."
  use HomeWeb, :live_view

  alias Home.Cognee.InsightTracker
  alias Home.GitActivity
  alias Home.LLMProxy.{ProviderCatalog, UsageTracker}
  alias Home.Secrets.Store

  on_mount {HomeWeb.LiveUserAuth, :live_user_optional}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Home.PubSub, "llm_usage")
      Phoenix.PubSub.subscribe(Home.PubSub, "cognee_insights")
    end

    {:ok,
     socket
     |> assign_new(:current_scope, fn -> nil end)
     |> assign(:secret_count, length(Store.list_all()))
     |> assign(:provider_options, provider_options())
     |> assign(:model_options, model_options())}
  end

  @impl true
  def handle_params(%{"project" => project}, _uri, socket) do
    {:noreply, load_project(socket, project)}
  end

  @impl true
  def handle_info(:llm_usage_updated, socket) do
    {:noreply, load_project(socket, socket.assigns.project_id)}
  end

  def handle_info(:cognee_insights_updated, socket) do
    {:noreply, load_project(socket, socket.assigns.project_id)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_project(socket, socket.assigns.project_id)}
  end

  def handle_event("toggle_project", _params, socket) do
    {:ok, _policy} =
      UsageTracker.set_project_policy(socket.assigns.project_id, %{
        enabled: !socket.assigns.details.policy.enabled
      })

    {:noreply, load_project(socket, socket.assigns.project_id)}
  end

  def handle_event("save_controls", %{"controls" => params}, socket) do
    provider = params["provider"] || ""
    default_model = params["default_model"] || ""

    with true <- provider in option_values(socket.assigns.provider_options),
         true <- default_model in option_values(socket.assigns.model_options),
         {:ok, quota} <- parse_quota(params["quota_usd"]) do
      {:ok, _policy} =
        UsageTracker.set_project_policy(socket.assigns.project_id, %{
          provider: provider,
          routing_mode: if(provider == "", do: "automatic", else: "pinned"),
          default_model: default_model,
          quota_usd: quota
        })

      {:noreply,
       socket
       |> load_project(socket.assigns.project_id)
       |> put_flash(:info, "Project routing controls updated")}
    else
      _ -> {:noreply, put_flash(socket, :error, "Choose valid project controls")}
    end
  end

  defp load_project(socket, project) do
    details = UsageTracker.project_details(project)
    models = Enum.map(details.models, &model_row/1)
    providers = Enum.map(details.providers, &provider_row/1)
    tools = Enum.map(details.tools, &tool_row/1)
    daily = daily_rows(details.daily)
    total_tokens = details.month.input_tokens + details.month.output_tokens
    git_project = Enum.find(GitActivity.recent(), &(&1.id == normalize_project(project)))
    commits = if(git_project, do: git_project.commits, else: [])

    memory_areas =
      InsightTracker.snapshot().areas
      |> Enum.filter(&(memory_project_id(&1.dataset_name) == normalize_project(project)))

    memory_rows = Enum.map(memory_areas, &memory_row/1)
    memory_total = Enum.sum(Enum.map(memory_areas, & &1.item_count))
    memory_day = Enum.sum(Enum.map(memory_areas, & &1.recent_day_count))
    memory_week = Enum.sum(Enum.map(memory_areas, & &1.recent_week_count))
    git_commit_count = length(commits)
    signal_count = Enum.count([details.month.calls, git_commit_count, memory_total], &(&1 > 0))

    socket
    |> assign(:page_title, "#{details.policy.name} · Project")
    |> assign(:project_id, details.project)
    |> assign(:tools_project?, details.project == "tools")
    |> assign(:details, details)
    |> assign(:controls_form, controls_form(details.policy))
    |> assign(:month_cost, money(details.month.cost_usd))
    |> assign(:month_calls, details.month.calls)
    |> assign(:month_tokens, compact(total_tokens))
    |> assign(:average_cost, money(safe_average(details.month.cost_usd, details.month.calls)))
    |> assign(:quota_percent, percent(details.month.cost_usd, details.policy.quota_usd))
    |> assign(:signal_count, signal_count)
    |> assign(:git_commit_count, git_commit_count)
    |> assign(:git_latest, relative_timestamp(git_project && git_project.latest_at))
    |> assign(:memory_total, compact(memory_total))
    |> assign(:memory_day, memory_day)
    |> assign(:memory_week, memory_week)
    |> assign(:memory_latest, relative_timestamp(latest_memory_activity(memory_areas)))
    |> assign(:cognee_graph_url, cognee_ui_url("/knowledge-graph"))
    |> assign(:commits_empty?, commits == [])
    |> assign(:memory_empty?, memory_rows == [])
    |> assign(:models_empty?, models == [])
    |> assign(:providers_empty?, providers == [])
    |> assign(:tools_empty?, tools == [])
    |> assign(:daily_empty?, daily == [])
    |> stream(:models, models, reset: true)
    |> stream(:providers, providers, reset: true)
    |> stream(:tools, tools, reset: true)
    |> stream(:daily, daily, reset: true)
    |> stream(:project_commits, commits, reset: true)
    |> stream(:memory_areas, memory_rows, reset: true)
  end

  defp controls_form(policy) do
    to_form(
      %{
        "provider" => if(policy.routing_mode == "pinned", do: policy.provider, else: ""),
        "default_model" => Map.get(policy, :default_model, ""),
        "quota_usd" => policy.quota_usd
      },
      as: :controls
    )
  end

  defp model_options do
    models =
      Home.LLMProxy.models().data
      |> Enum.map(& &1.id)
      |> Enum.uniq()
      |> Enum.sort()

    [{"Respect requested model", ""}] ++ Enum.map(models, &{&1, &1})
  end

  defp provider_options do
    [{"Automatic failover", ""}] ++
      Enum.map(ProviderCatalog.names() |> Enum.sort(), fn provider ->
        {provider |> to_string() |> String.replace("_", " ") |> String.upcase(),
         to_string(provider)}
      end)
  end

  defp model_row(model) do
    %{
      id: model.id,
      name: model.model,
      providers: Enum.join(model.providers, " / "),
      calls: model.calls,
      tokens: compact(model.input_tokens + model.output_tokens),
      cost: money(model.cost_usd),
      latency: latency(model.latency_ms),
      share: 0
    }
  end

  defp provider_row(provider) do
    %{
      id: provider.provider,
      name: provider.provider,
      calls: provider.calls,
      tokens: compact(provider.input_tokens + provider.output_tokens),
      cost: money(provider.cost_usd),
      latency: latency(provider.latency_ms)
    }
  end

  defp tool_row(tool) do
    %{
      id: tool.id,
      name: tool.name,
      category: tool.category,
      models: if(tool.models == [], do: "AWAITING TRAFFIC", else: Enum.join(tool.models, " / ")),
      providers: tool.provider_count,
      calls: tool.calls,
      tokens: compact(tool.input_tokens + tool.output_tokens),
      cost: money(tool.cost_usd),
      latency: latency(tool.latency_ms)
    }
  end

  defp memory_row(area) do
    %{
      id: area.dataset_id,
      name: area.dataset_name |> String.replace_prefix("ocp-", "") |> String.replace("-", " "),
      records: compact(area.item_count),
      day: area.recent_day_count,
      week: area.recent_week_count,
      latest: relative_timestamp(area.latest_activity_at),
      url: cognee_ui_url("/datasets/#{area.dataset_id}")
    }
  end

  defp cognee_ui_url(path) do
    endpoint =
      :home
      |> Application.get_env(:cognee_insights, [])
      |> Keyword.get(:ui_endpoint, "http://localhost:3000")
      |> String.trim_trailing("/")

    endpoint <> path
  end

  defp daily_rows([]), do: []

  defp daily_rows(rows) do
    max_tokens = Enum.max(Enum.map(rows, &(&1.input_tokens + &1.output_tokens)), fn -> 1 end)

    Enum.map(rows, fn row ->
      tokens = row.input_tokens + row.output_tokens

      %{
        id: Date.to_iso8601(row.date),
        date: Calendar.strftime(row.date, "%d %b"),
        calls: row.calls,
        tokens: compact(tokens),
        cost: money(row.cost_usd),
        width: max(round(tokens / max(max_tokens, 1) * 100), 3)
      }
    end)
  end

  defp parse_quota(value) when is_number(value) and value >= 0, do: {:ok, value * 1.0}

  defp parse_quota(value) when is_binary(value) do
    case Float.parse(value) do
      {quota, ""} when quota >= 0 -> {:ok, quota}
      _ -> :error
    end
  end

  defp parse_quota(_value), do: :error
  defp option_values(options), do: Enum.map(options, &elem(&1, 1))
  defp safe_average(_value, 0), do: 0.0
  defp safe_average(value, count), do: value / count
  defp percent(_value, quota) when quota <= 0, do: 0
  defp percent(value, quota), do: min(round(value / quota * 100), 100)
  defp latency(nil), do: "NO SAMPLE"
  defp latency(value), do: "#{value}ms"

  defp compact(value) when value >= 1_000_000,
    do: :erlang.float_to_binary(value / 1_000_000, decimals: 1) <> "M"

  defp compact(value) when value >= 1_000,
    do: :erlang.float_to_binary(value / 1_000, decimals: 1) <> "K"

  defp compact(value), do: Integer.to_string(value)
  defp money(value), do: "$" <> :erlang.float_to_binary(value * 1.0, decimals: 4)

  defp normalize_project(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp memory_project_id(name) do
    name |> String.replace_prefix("ocp-", "") |> normalize_project()
  end

  defp latest_memory_activity(areas) do
    areas
    |> Enum.map(& &1.latest_activity_at)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp relative_timestamp(nil), do: "NO RECENT SIGNAL"

  defp relative_timestamp(datetime) do
    seconds = max(DateTime.diff(DateTime.utc_now(), datetime, :second), 0)

    cond do
      seconds < 60 -> "NOW"
      seconds < 3_600 -> "#{div(seconds, 60)}M AGO"
      seconds < 86_400 -> "#{div(seconds, 3_600)}H AGO"
      true -> "#{div(seconds, 86_400)}D AGO"
    end
  end
end
