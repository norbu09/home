defmodule HomeWeb.RouterLive do
  @moduledoc "LLM router operations dashboard."
  use HomeWeb, :live_view

  alias Home.LLMProxy.{ProviderCatalog, ProviderHealth, UsageTracker}
  alias Home.Secrets.Store

  on_mount {HomeWeb.LiveUserAuth, :live_user_optional}

  @routing_modes [
    {"Automatic - best available", "automatic"},
    {"Pin to provider", "pinned"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Home.PubSub, "llm_usage")

    {:ok,
     socket
     |> assign(:page_title, "LLM Router")
     |> assign_new(:current_scope, fn -> nil end)
     |> assign(:selected_project, nil)
     |> assign(:routing_form, nil)
     |> assign(:routing_modes, @routing_modes)
     |> load_dashboard()}
  end

  @impl true
  def handle_info(:llm_usage_updated, socket), do: {:noreply, load_dashboard(socket)}

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load_dashboard(socket)}

  def handle_event("toggle_project", %{"id" => project_id}, socket) do
    project = Enum.find(socket.assigns.projects, &(&1.id == project_id))

    if project do
      {:ok, _policy} = UsageTracker.set_project_policy(project_id, %{enabled: !project.enabled})
      {:noreply, load_dashboard(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_project", %{"id" => project_id}, socket) do
    case Enum.find(socket.assigns.projects, &(&1.id == project_id)) do
      nil ->
        {:noreply, socket}

      project ->
        {:noreply,
         socket
         |> assign(:selected_project, project)
         |> assign(:routing_form, routing_form(project))}
    end
  end

  def handle_event("close_project", _params, socket) do
    {:noreply, assign(socket, selected_project: nil, routing_form: nil)}
  end

  def handle_event("save_routing", %{"routing" => params}, socket) do
    project = socket.assigns.selected_project
    routing_mode = params["routing_mode"]
    provider = params["provider"]
    providers = Enum.map(socket.assigns.provider_options, &elem(&1, 1))
    valid_provider? = provider in providers && (routing_mode == "automatic" || provider != "")

    if project && routing_mode in Enum.map(@routing_modes, &elem(&1, 1)) && valid_provider? do
      {:ok, _policy} =
        UsageTracker.set_project_policy(project.id, %{
          routing_mode: routing_mode,
          provider: if(routing_mode == "pinned", do: provider, else: "")
        })

      {:noreply,
       socket
       |> load_dashboard()
       |> put_flash(:info, "Routing policy updated for #{project.name}")}
    else
      {:noreply, put_flash(socket, :error, "Choose a valid routing policy")}
    end
  end

  defp load_dashboard(socket) do
    snapshot = UsageTracker.snapshot()
    projects = Enum.map(snapshot.projects, &project_view/1)
    tools = Enum.map(snapshot.tools, &tool_view/1)
    providers = provider_views(snapshot.providers)
    total_quota = Enum.sum(Enum.map(projects, & &1.limit))
    monthly_cost = snapshot.month.cost_usd
    total_tokens = snapshot.month.input_tokens + snapshot.month.output_tokens
    selected_project = refresh_selected(socket.assigns[:selected_project], projects)

    socket
    |> assign(:snapshot, snapshot)
    |> assign(:projects, projects)
    |> assign(:tools, tools)
    |> assign(:providers, providers)
    |> assign(:project_count, length(projects))
    |> assign(:tool_count, length(tools))
    |> assign(:provider_count, Enum.count(providers, & &1.configured))
    |> assign(:secret_count, length(Store.list_all()))
    |> assign(:month_label, Calendar.strftime(snapshot.updated_at, "%B %Y"))
    |> assign(:monthly_cost, money(monthly_cost))
    |> assign(:cost_delta, "DB + ETS current cycle")
    |> assign(:total_tokens, compact_number(total_tokens))
    |> assign(
      :today_tokens,
      compact_number(snapshot.today.input_tokens + snapshot.today.output_tokens)
    )
    |> assign(:request_count, integer(snapshot.month.calls))
    |> assign(:success_rate, provider_success_rate(providers))
    |> assign(:budget_available, money(max(total_quota - monthly_cost, 0.0)))
    |> assign(:budget_percent, percent(monthly_cost, total_quota))
    |> assign(:quota_warning, Enum.max_by(projects, & &1.percent, fn -> nil end))
    |> assign(:provider_options, provider_options())
    |> assign(:selected_project, selected_project)
    |> assign(:routing_form, selected_project && routing_form(selected_project))
    |> stream(:projects, projects, reset: true)
    |> stream(:tools, tools, reset: true)
    |> stream(:providers, providers, reset: true)
  end

  defp project_view(project) do
    quota = project.quota_usd || 0.0
    usage_percent = percent(project.cost_usd, quota)

    %{
      id: project.id,
      code: String.upcase(project.id),
      key: "PRJ_" <> (project.id |> String.upcase() |> String.slice(0, 12)),
      name: project.name,
      last_seen: relative_time(project.last_seen_at),
      spend: money(project.cost_usd),
      used: money_number(project.cost_usd),
      limit: quota,
      limit_label: money_number(quota),
      percent: usage_percent,
      requests: integer(project.calls),
      input_tokens: project.input_tokens,
      output_tokens: project.output_tokens,
      routing_mode: project.routing_mode,
      provider: project.provider,
      enabled: project.enabled,
      warning: quota > 0 && usage_percent >= 80
    }
  end

  defp provider_views(usage_rows) do
    usage = Map.new(usage_rows, &{&1.provider, &1})
    health = ProviderHealth.snapshot()
    total_cost = Enum.sum(Enum.map(usage_rows, & &1.cost_usd))

    ProviderCatalog.names()
    |> Enum.sort()
    |> Enum.map(fn provider ->
      provider_name = to_string(provider)
      row = Map.get(usage, provider_name, %{calls: 0, cost_usd: 0.0, latency_ms: nil})
      state = Map.get(health, provider_name, %{})
      configured = provider_configured?(provider)

      %{
        id: provider_name,
        name: String.upcase(provider_name),
        configured: configured,
        status: provider_status(configured, state),
        warning: provider_warning?(state),
        latency: latency_label(row.latency_ms || state[:latency_ms]),
        cost: money(row.cost_usd),
        share: "#{percent(row.cost_usd, total_cost)}%",
        calls: row.calls
      }
    end)
  end

  defp tool_view(tool) do
    %{
      id: tool.id,
      code: String.upcase(tool.id),
      name: tool.name,
      category: String.upcase(tool.category),
      spend: money(tool.cost_usd),
      calls: integer(tool.calls),
      providers: "#{tool.provider_count} providers",
      latency: latency_label(tool.latency_ms),
      last_seen: relative_time(tool.last_seen_at)
    }
  end

  defp provider_configured?(provider) do
    case ProviderCatalog.fetch(provider) do
      {:ok, module} ->
        module.env_vars() == [] || Enum.any?(module.env_vars(), &Store.env_available?/1)

      _ ->
        false
    end
  end

  defp provider_status(false, _state), do: "NOT CONFIGURED"

  defp provider_status(true, %{locked_until: locked_until}) when is_integer(locked_until),
    do: "DEGRADED"

  defp provider_status(true, %{last_success: _}), do: "HEALTHY"
  defp provider_status(true, _state), do: "READY"

  defp provider_warning?(%{locked_until: locked_until}) when is_integer(locked_until),
    do: locked_until > System.system_time(:millisecond)

  defp provider_warning?(_state), do: false

  defp provider_options do
    [{"No override", ""}] ++
      Enum.map(ProviderCatalog.names() |> Enum.sort(), fn provider ->
        {provider |> to_string() |> String.replace("_", " ") |> String.capitalize(),
         to_string(provider)}
      end)
  end

  defp refresh_selected(nil, _projects), do: nil
  defp refresh_selected(selected, projects), do: Enum.find(projects, &(&1.id == selected.id))

  defp routing_form(project) do
    to_form(%{"routing_mode" => project.routing_mode, "provider" => project.provider},
      as: :routing
    )
  end

  defp routing_label(%{routing_mode: "pinned", provider: provider}), do: String.upcase(provider)
  defp routing_label(_project), do: "AUTO_SELECT"

  defp provider_success_rate(providers) do
    configured = Enum.filter(providers, & &1.configured)
    healthy = Enum.count(configured, &(&1.status in ["HEALTHY", "READY"]))
    if configured == [], do: "0%", else: "#{round(healthy / length(configured) * 100)}%"
  end

  defp percent(_used, total) when total <= 0, do: 0
  defp percent(used, total), do: min(round(used / total * 100), 100)
  defp money(value), do: "$" <> :erlang.float_to_binary(value * 1.0, decimals: 2)
  defp money_number(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2)
  defp integer(value), do: value |> trunc() |> Integer.to_string() |> add_delimiters()

  defp compact_number(value) when value >= 1_000_000,
    do: :erlang.float_to_binary(value / 1_000_000, decimals: 1) <> "M"

  defp compact_number(value) when value >= 1_000,
    do: :erlang.float_to_binary(value / 1_000, decimals: 1) <> "K"

  defp compact_number(value), do: integer(value)

  defp add_delimiters(value),
    do: value |> String.reverse() |> String.replace(~r/(\d{3})(?=\d)/, "\\1,") |> String.reverse()

  defp latency_label(nil), do: "NO CALLS"
  defp latency_label(ms), do: "#{ms}MS"

  defp relative_time(nil), do: "NO CALLS"

  defp relative_time(datetime) do
    seconds = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      seconds < 60 -> "#{seconds}S AGO"
      seconds < 3_600 -> "#{div(seconds, 60)}M AGO"
      seconds < 86_400 -> "#{div(seconds, 3_600)}H AGO"
      true -> "#{div(seconds, 86_400)}D AGO"
    end
  end
end
