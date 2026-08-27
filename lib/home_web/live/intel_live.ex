defmodule HomeWeb.IntelLive do
  @moduledoc "Operational screens for Home services and LLM router intelligence."
  use HomeWeb, :live_view

  alias Home.LLMProxy.{ProviderCatalog, ProviderHealth, UsageLog, UsageTracker}
  alias Home.Secrets.Store

  on_mount {HomeWeb.LiveUserAuth, :live_user_optional}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Home.PubSub, "llm_usage")

    {:ok,
     socket
     |> assign_new(:current_scope, fn -> nil end)
     |> assign(:secret_count, length(Store.list_all()))
     |> load_action()}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, load_action(socket)}

  @impl true
  def handle_info(:llm_usage_updated, socket), do: {:noreply, load_action(socket)}

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load_action(socket)}

  def handle_event("toggle_policy", %{"id" => id}, socket) do
    policy = UsageTracker.policy(id)
    {:ok, _policy} = UsageTracker.set_project_policy(id, %{enabled: !policy.enabled})
    {:noreply, load_action(socket)}
  end

  def handle_event("set_provider", %{"id" => id, "provider" => provider}, socket) do
    attrs =
      if provider == "" do
        %{routing_mode: "automatic", provider: ""}
      else
        %{routing_mode: "pinned", provider: provider}
      end

    {:ok, _policy} = UsageTracker.set_project_policy(id, attrs)
    {:noreply, load_action(socket)}
  end

  def handle_event("set_provider", %{"_id" => id, "policy" => %{"provider" => provider}}, socket) do
    handle_event("set_provider", %{"id" => id, "provider" => provider}, socket)
  end

  defp load_action(%{assigns: %{live_action: :services}} = socket) do
    services = service_rows()

    socket
    |> assign(:page_title, "Services")
    |> assign(:active_nav, :services)
    |> assign(:page_kicker, "// Local runtime mesh")
    |> assign(:page_heading, "SERVICE STATUS")
    |> assign(:page_summary, "Supervised processes and core dependencies")
    |> assign(:service_count, length(services))
    |> assign(:healthy_count, Enum.count(services, &(&1.status == "ONLINE")))
    |> stream(:services, services, reset: true)
  end

  defp load_action(%{assigns: %{live_action: :providers}} = socket) do
    providers = provider_rows()

    socket
    |> assign(:page_title, "Providers")
    |> assign(:active_nav, :providers)
    |> assign(:page_kicker, "// Model provider mesh")
    |> assign(:page_heading, "PROVIDER INTELLIGENCE")
    |> assign(:page_summary, "Configuration, health, latency, and model inventory")
    |> assign(:provider_count, length(providers))
    |> assign(:configured_count, Enum.count(providers, & &1.configured))
    |> assign(:provider_options, provider_options())
    |> stream(:providers, providers, reset: true)
  end

  defp load_action(%{assigns: %{live_action: :requests}} = socket) do
    requests = Enum.map(UsageLog.recent_batches(), &request_row/1)

    socket
    |> assign(:page_title, "Request Log")
    |> assign(:active_nav, :requests)
    |> assign(:page_kicker, "// Persisted accounting trail")
    |> assign(:page_heading, "REQUEST LOG")
    |> assign(:page_summary, "Recent ETS sweep batches, newest first")
    |> assign(:request_batches_empty?, requests == [])
    |> assign(:batch_count, length(requests))
    |> stream(:requests, requests, reset: true)
  end

  defp load_action(%{assigns: %{live_action: :policies}} = socket) do
    projects =
      Enum.map(UsageTracker.snapshot().projects, fn project ->
        Map.put(
          project,
          :form,
          to_form(%{"id" => project.id, "provider" => policy_provider(project)}, as: :policy)
        )
      end)

    socket
    |> assign(:page_title, "Policies")
    |> assign(:active_nav, :policies)
    |> assign(:page_kicker, "// Project routing controls")
    |> assign(:page_heading, "POLICY MATRIX")
    |> assign(:page_summary, "Request access, quotas, and provider constraints")
    |> assign(:provider_options, provider_options())
    |> assign(:policy_count, length(projects))
    |> stream(:policies, projects, reset: true)
  end

  defp service_rows do
    [
      service("web_gateway", "Phoenix / Bandit", HomeWeb.Endpoint, "HTTP + LiveView ingress"),
      service("database", "PostgreSQL", Home.Repo, "Historic state and encrypted metadata"),
      service("llm_router", "LLM Router", UsageTracker, "Project routing and accounting"),
      service("provider_health", "Provider Health", ProviderHealth, "Failover and lockout state"),
      service("event_bus", "Local Event Bus", Home.PubSub, "Live tactical updates")
    ]
  end

  defp service(id, name, process, detail) do
    pid = Process.whereis(process)

    %{
      id: id,
      name: name,
      detail: detail,
      process: inspect(process),
      status: if(is_pid(pid), do: "ONLINE", else: "OFFLINE"),
      pid: if(is_pid(pid), do: inspect(pid), else: "NOT REGISTERED")
    }
  end

  defp provider_rows do
    health = ProviderHealth.snapshot()
    usage = UsageTracker.snapshot().providers |> Map.new(&{&1.provider, &1})

    ProviderCatalog.names()
    |> Enum.sort()
    |> Enum.map(fn provider ->
      {:ok, module} = ProviderCatalog.fetch(provider)
      id = to_string(provider)
      env_vars = module.env_vars()
      configured = env_vars == [] || Enum.any?(env_vars, &Store.env_available?/1)
      state = Map.get(health, id, %{})
      row = Map.get(usage, id, %{calls: 0, cost_usd: 0.0, latency_ms: nil})

      %{
        id: id,
        name: id |> String.replace("_", " ") |> String.upcase(),
        configured: configured,
        status: provider_status(configured, state),
        models: length(module.default_models()),
        credentials: if(env_vars == [], do: "LOCAL", else: Enum.join(env_vars, " / ")),
        calls: row.calls,
        cost: money(row.cost_usd),
        latency: latency(row.latency_ms || state[:latency_ms])
      }
    end)
  end

  defp provider_status(false, _state), do: "UNCONFIGURED"

  defp provider_status(true, %{locked_until: until_ms}) when is_integer(until_ms),
    do: if(until_ms > System.system_time(:millisecond), do: "DEGRADED", else: "READY")

  defp provider_status(true, %{last_success: _}), do: "HEALTHY"
  defp provider_status(true, _state), do: "READY"

  defp request_row(log) do
    %{
      id: log.id,
      project: log.project,
      provider: log.provider,
      model: log.model,
      calls: log.calls,
      tokens: log.input_tokens + log.output_tokens,
      cost: money(log.cost_micros / 1_000_000),
      latency: latency(if(log.calls > 0, do: div(log.latency_total_ms, log.calls), else: nil)),
      recorded_at: Calendar.strftime(log.inserted_at, "%Y-%m-%d %H:%M:%SZ")
    }
  end

  defp provider_options do
    [{"Automatic", ""}] ++
      Enum.map(
        ProviderCatalog.names() |> Enum.sort(),
        &{String.upcase(to_string(&1)), to_string(&1)}
      )
  end

  defp policy_provider(%{routing_mode: "pinned", provider: provider}), do: provider
  defp policy_provider(_project), do: ""

  defp latency(nil), do: "NO SAMPLE"
  defp latency(value), do: "#{value}ms"
  defp money(value), do: "$" <> :erlang.float_to_binary(value * 1.0, decimals: 4)
end
