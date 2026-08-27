defmodule Home.LLMProxy.ModelRouting do
  @moduledoc """
  Local model routing for OpenAI-compatible proxy clients.

  The defaults are adapted from kfos_agent's role chains. Runtime config can
  override them with:

      config :home, :llm_proxy,
        default_model: {:zai, "glm-5.2"},
        model_groups: %{
          "glm-5.2" => [
            %{provider: :zai, model: "glm-5.2", order: 1, cost: %{input: 0.0, output: 0.0}},
            %{provider: :openrouter, model: "z-ai/glm-5.2", order: 2}
          ]
        },
        role_chains: %{"coder" => [{:zai, "glm-5.2"}, {:openrouter, "z-ai/glm-5.2"}]}
  """

  alias Home.LLMProxy.{ModelRoute, ProviderCatalog}
  alias Home.Secrets.Store

  @role_chains %{
    "coder" => [
      {:zai, "glm-5.2"},
      {:kimi_coding, "kimi-for-coding"},
      {:openrouter, "moonshotai/kimi-k3"}
    ],
    "qa" => [{:kimi_coding, "kimi-for-coding"}, {:zai, "glm-5.2"}],
    "planner" => [{:zai, "glm-5.2"}, {:kimi_coding, "kimi-for-coding"}],
    "memory" => [
      {:openrouter, "openai/text-embedding-3-small"},
      {:openai, "text-embedding-3-small"},
      {:ollama, "nomic-embed-text"}
    ]
  }

  @tiers %{
    "strong" => "coder",
    "primary" => "coder",
    "fast" => "planner",
    "quality" => "planner",
    "embedding" => "memory",
    "embeddings" => "memory"
  }

  @model_groups %{}

  @openrouter_vendor_prefix %{
    "zai" => "z-ai",
    "anthropic" => "anthropic",
    "kimi_coding" => "moonshotai",
    "moonshot" => "moonshotai"
  }

  @openrouter_model_ids %{
    {"kimi_coding", "kimi-for-coding"} => "moonshotai/kimi-k3",
    {"moonshot", "kimi-for-coding"} => "moonshotai/kimi-k3"
  }

  @doc "Resolve the OpenAI `model` field into an ordered provider failover chain."
  def resolve_chain(model, kind \\ :chat) do
    {chain, expand_same_model?} = do_resolve_chain(model, kind, MapSet.new())

    chain
    |> expand_same_model_openrouter(expand_same_model?)
    |> Enum.uniq()
    |> configured_or_original()
    |> Home.LLMProxy.ProviderHealth.order_chain()
  end

  @doc "Logical proxy model IDs advertised through `/v1/models`."
  def public_models do
    (db_model_groups() ++ config_model_groups())
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&%{id: &1, object: "model", owned_by: "home"})
  end

  @doc "Create or update a single DB-backed route for a logical model group."
  def upsert_model_route(model_group, attrs) when is_binary(model_group) and is_map(attrs) do
    attrs
    |> Map.put(:model_group, model_group)
    |> ModelRoute.upsert()
  end

  @doc "Replace a logical model group's DB routes."
  def replace_model_group(model_group, routes) when is_binary(model_group) and is_list(routes) do
    Home.Repo.transaction(fn ->
      ModelRoute.delete_group(model_group)

      Enum.map(routes, fn route ->
        attrs =
          route
          |> route_attrs()
          |> Map.put(:model_group, model_group)

        case ModelRoute.upsert(attrs) do
          {:ok, route} -> route
          {:error, changeset} -> Home.Repo.rollback(changeset)
        end
      end)
    end)
  end

  @doc "Seed DB routes from config model groups without restarting the proxy."
  def seed_config_model_groups do
    :home
    |> Application.get_env(:llm_proxy, [])
    |> Keyword.get(:model_groups, @model_groups)
    |> Enum.map(fn {model_group, routes} -> replace_model_group(model_group, routes) end)
  end

  defp do_resolve_chain(model, kind, seen) when is_binary(model) do
    trimmed = String.trim(model)

    cond do
      MapSet.member?(seen, trimmed) ->
        {[], false}

      group = db_model_group(trimmed) ->
        {db_group_chain(group), false}

      group = configured_model_group(trimmed) ->
        {group_chain(group), false}

      alias_target = configured_model_alias(trimmed) ->
        resolve_model_alias(alias_target, kind, MapSet.put(seen, trimmed))

      parsed = parse_provider_model(trimmed) ->
        {[parsed], false}

      role = configured_alias(trimmed) ->
        {role_chain(role), true}

      role = Map.get(@tiers, trimmed) ->
        {role_chain(role), true}

      true ->
        {fallback_chain(kind), true}
    end
  end

  defp do_resolve_chain(_, kind, _seen), do: {fallback_chain(kind), true}

  defp resolve_model_alias(target, kind, seen) when is_binary(target) do
    do_resolve_chain(target, kind, seen)
  end

  defp resolve_model_alias(chain, _kind, _seen) do
    {List.wrap(chain), false}
  end

  defp parse_provider_model(model) do
    case String.split(model, "/", parts: 2) do
      [provider, id] when provider != "" and id != "" ->
        with {:ok, provider_atom} <- existing_provider_atom(provider),
             {:ok, _module} <- ProviderCatalog.fetch(provider_atom) do
          {provider_atom, id}
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp existing_provider_atom(provider) do
    {:ok, String.to_existing_atom(provider)}
  rescue
    ArgumentError -> :error
  end

  defp configured_alias(model) do
    :home
    |> Application.get_env(:llm_proxy, [])
    |> Keyword.get(:model_roles, %{})
    |> Map.get(model)
  end

  defp configured_model_alias(model) do
    :home
    |> Application.get_env(:llm_proxy, [])
    |> Keyword.get(:model_aliases, %{})
    |> Map.get(model)
  end

  defp configured_model_group(model) do
    :home
    |> Application.get_env(:llm_proxy, [])
    |> Keyword.get(:model_groups, @model_groups)
    |> Map.get(model)
  end

  defp db_model_group(model) do
    model
    |> ModelRoute.enabled_for_group()
    |> case do
      [] -> nil
      routes -> routes
    end
  rescue
    _ -> nil
  end

  defp db_group_chain(routes) when is_list(routes) do
    routes
    |> Enum.map(&normalize_db_route/1)
    |> Enum.reject(&is_nil/1)
    |> sort_group_routes()
    |> Enum.map(& &1.route)
  end

  defp normalize_db_route(%ModelRoute{} = route) do
    with {:ok, provider_atom} <- provider_atom(route.provider),
         true <- is_binary(route.model) and String.trim(route.model) != "" do
      cost =
        if route.input_cost_per_million || route.output_cost_per_million do
          %{input: route.input_cost_per_million, output: route.output_cost_per_million}
        end

      %{
        route: {provider_atom, String.trim(route.model)},
        order: route.order || 1,
        priority: route.priority || 0,
        cost: cost
      }
    else
      _ -> nil
    end
  end

  defp group_chain(routes) when is_list(routes) do
    routes
    |> Enum.map(&normalize_group_route/1)
    |> Enum.reject(&is_nil/1)
    |> sort_group_routes()
    |> Enum.map(& &1.route)
  end

  defp group_chain(_routes), do: []

  defp normalize_group_route({provider, model}) when is_atom(provider) and is_binary(model) do
    %{route: {provider, model}, order: 1, cost: nil}
  end

  defp normalize_group_route(route) when is_map(route) do
    provider = Map.get(route, :provider) || Map.get(route, "provider")
    model = Map.get(route, :model) || Map.get(route, "model")

    with {:ok, provider_atom} <- provider_atom(provider),
         true <- is_binary(model) and String.trim(model) != "" do
      %{
        route: {provider_atom, String.trim(model)},
        order: order_value(Map.get(route, :order) || Map.get(route, "order")),
        priority: order_value(Map.get(route, :priority) || Map.get(route, "priority") || 0),
        cost: Map.get(route, :cost) || Map.get(route, "cost")
      }
    else
      _ -> nil
    end
  end

  defp normalize_group_route(_route), do: nil

  defp route_attrs(%ModelRoute{} = route) do
    %{
      provider: route.provider,
      model: route.model,
      order: route.order,
      priority: route.priority,
      input_cost_per_million: route.input_cost_per_million,
      output_cost_per_million: route.output_cost_per_million,
      enabled: route.enabled,
      notes: route.notes
    }
  end

  defp route_attrs(%{cost: cost} = route) when is_map(cost) do
    route
    |> Map.delete(:cost)
    |> Map.delete("cost")
    |> Map.put(:input_cost_per_million, Map.get(cost, :input) || Map.get(cost, "input"))
    |> Map.put(:output_cost_per_million, Map.get(cost, :output) || Map.get(cost, "output"))
  end

  defp route_attrs(route) when is_map(route), do: route

  defp route_attrs({provider, model}) do
    %{provider: provider, model: model, order: 1, priority: 0, enabled: true}
  end

  defp provider_atom(provider) when is_atom(provider) do
    if provider in ProviderCatalog.names(), do: {:ok, provider}, else: :error
  end

  defp provider_atom(provider) when is_binary(provider) do
    provider
    |> String.trim()
    |> existing_provider_atom()
  end

  defp provider_atom(_provider), do: :error

  defp order_value(order) when is_integer(order), do: order

  defp order_value(order) when is_binary(order) do
    case Integer.parse(order) do
      {parsed, ""} -> parsed
      _ -> 1
    end
  end

  defp order_value(_order), do: 1

  defp sort_group_routes(routes) do
    routes
    |> Enum.group_by(& &1.order)
    |> Enum.sort_by(fn {order, _routes} -> order end)
    |> Enum.flat_map(fn {_order, tier_routes} ->
      Enum.sort_by(tier_routes, fn route ->
        {route_cost_score(route), route.priority || 0, elem(route.route, 0), elem(route.route, 1)}
      end)
    end)
  end

  defp route_cost_score(%{cost: %{input: input, output: output}}),
    do: number_value(input) + number_value(output)

  defp route_cost_score(%{cost: %{"input" => input, "output" => output}}),
    do: number_value(input) + number_value(output)

  defp route_cost_score(%{route: {_provider, model}}) do
    case price_for(model) do
      %{input: input, output: output} -> number_value(input) + number_value(output)
      %{"input" => input, "output" => output} -> number_value(input) + number_value(output)
      _ -> :infinity
    end
  end

  defp number_value(value) when is_number(value), do: value * 1.0
  defp number_value(%Decimal{} = value), do: Decimal.to_float(value)

  defp number_value(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      _ -> 0.0
    end
  end

  defp number_value(_value), do: 0.0

  defp role_chain(role) do
    overrides =
      :home
      |> Application.get_env(:llm_proxy, [])
      |> Keyword.get(:role_chains, %{})

    Map.get(overrides, to_string(role)) || Map.get(@role_chains, to_string(role), [])
  end

  defp fallback_chain(:embedding), do: role_chain("memory")

  defp fallback_chain(_kind) do
    :home
    |> Application.get_env(:llm_proxy, [])
    |> Keyword.get(:default_model)
    |> List.wrap()
    |> Kernel.++(role_chain("coder"))
  end

  defp expand_same_model_openrouter(chain, true),
    do: Enum.flat_map(chain, &with_same_model_openrouter/1)

  defp expand_same_model_openrouter(chain, false), do: chain

  defp with_same_model_openrouter({provider, model_id} = model) do
    [model, openrouter_same_model(provider, model_id)] |> Enum.reject(&is_nil/1)
  end

  defp openrouter_same_model(:openrouter, _model_id), do: nil

  defp openrouter_same_model(provider, model_id) when is_binary(model_id) do
    provider = to_string(provider)

    cond do
      slug = Map.get(@openrouter_model_ids, {provider, model_id}) ->
        {:openrouter, slug}

      prefix = Map.get(@openrouter_vendor_prefix, provider) ->
        {:openrouter, prefix <> "/" <> model_id}

      true ->
        nil
    end
  end

  defp configured_or_original(chain) do
    configured = Enum.filter(chain, &configured?/1)
    if configured == [], do: chain, else: configured
  end

  defp configured?({provider, _model_id}) do
    with {:ok, module} <- ProviderCatalog.fetch(provider) do
      module.env_vars() == [] || Enum.any?(module.env_vars(), &Store.env_available?/1)
    else
      _ -> false
    end
  end

  defp db_model_groups do
    ModelRoute.enabled_group_names()
  rescue
    _ -> []
  end

  defp config_model_groups do
    :home
    |> Application.get_env(:llm_proxy, [])
    |> Keyword.get(:model_groups, @model_groups)
    |> Map.keys()
  end

  defp price_for(model) do
    :home
    |> Application.get_env(:llm_model_prices, %{})
    |> lookup_price(model)
  end

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
end
