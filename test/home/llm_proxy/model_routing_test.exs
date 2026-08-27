defmodule Home.LLMProxy.ModelRoutingTest do
  use Home.DataCase, async: false

  alias Home.LLMProxy.ModelRoute
  alias Home.LLMProxy.ModelRouting
  alias Home.LLMProxy.ProviderHealth

  setup do
    old_proxy = Application.get_env(:home, :llm_proxy, [])
    old_prices = Application.get_env(:home, :llm_model_prices, %{})

    Application.put_env(:home, :llm_model_prices, %{
      "free-primary" => %{input: 0.0, output: 0.0},
      "free-backup" => %{input: 0.0, output: 0.0},
      "paid-cheap" => %{input: 0.25, output: 1.0},
      "paid-expensive" => %{input: 1.0, output: 4.0}
    })

    Application.put_env(:home, :llm_proxy,
      model_groups: %{
        "config-demo" => [
          %{provider: :ollama, model: "config-route", order: 1}
        ],
        "background-free" => [
          %{provider: :openrouter, model: "free-primary", order: 1, priority: 10},
          %{provider: :openrouter, model: "free-backup", order: 1, priority: 20},
          %{provider: :ollama, model: "paid-cheap", order: 2, priority: 10}
        ]
      },
      model_aliases: %{
        "cognee-chat" => "background-free",
        "openai/background-free" => "background-free"
      }
    )

    ProviderHealth.reset()

    on_exit(fn ->
      Application.put_env(:home, :llm_proxy, old_proxy)
      Application.put_env(:home, :llm_model_prices, old_prices)
      ProviderHealth.reset()
    end)

    :ok
  end

  test "resolves model groups by order tier and cost within a tier" do
    assert {:ok, _route} =
             ModelRouting.upsert_model_route("cost-demo", %{
               provider: :ollama,
               model: "paid-expensive",
               order: 2
             })

    assert {:ok, _route} =
             ModelRouting.upsert_model_route("cost-demo", %{
               provider: :ollama,
               model: "subscription",
               order: 1,
               cost: %{input: 0.0, output: 0.0}
             })

    assert {:ok, _route} =
             ModelRouting.upsert_model_route("cost-demo", %{
               provider: :ollama,
               model: "paid-cheap",
               order: 2
             })

    assert ModelRouting.resolve_chain("cost-demo") == [
             {:ollama, "subscription"},
             {:ollama, "paid-cheap"},
             {:ollama, "paid-expensive"}
           ]
  end

  test "advertises configured model groups as public proxy models" do
    assert {:ok, _route} =
             ModelRouting.upsert_model_route("cost-demo", %{
               provider: :ollama,
               model: "subscription",
               order: 1
             })

    assert %{id: "config-demo", object: "model", owned_by: "home"} in ModelRouting.public_models()
    assert %{id: "cost-demo", object: "model", owned_by: "home"} in ModelRouting.public_models()
  end

  test "DB routes override config routes without restart" do
    assert ModelRouting.resolve_chain("config-demo") == [{:ollama, "config-route"}]

    assert {:ok, _routes} =
             ModelRouting.replace_model_group("config-demo", [
               %{provider: :ollama, model: "db-route", order: 1}
             ])

    assert [%ModelRoute{model: "db-route"}] = ModelRoute.enabled_for_group("config-demo")
    assert ModelRouting.resolve_chain("config-demo") == [{:ollama, "db-route"}]
  end

  test "free background routes fail over in configured priority order" do
    assert ModelRouting.resolve_chain("background-free") == [
             {:openrouter, "free-primary"},
             {:openrouter, "free-backup"},
             {:ollama, "paid-cheap"}
           ]
  end

  test "route-level health does not remove every OpenRouter fallback" do
    ProviderHealth.report_error({:openrouter, "free-primary"}, :error)
    _ = :sys.get_state(ProviderHealth)

    assert ModelRouting.resolve_chain("background-free") == [
             {:openrouter, "free-backup"},
             {:ollama, "paid-cheap"}
           ]
  end

  test "model aliases can point at DB-backed logical groups" do
    assert {:ok, _routes} =
             ModelRouting.replace_model_group("background-free", [
               %{provider: :openrouter, model: "db-free-primary", order: 1, priority: 10},
               %{provider: :openrouter, model: "db-free-backup", order: 1, priority: 20}
             ])

    assert ModelRouting.resolve_chain("cognee-chat") == [
             {:openrouter, "db-free-primary"},
             {:openrouter, "db-free-backup"}
           ]

    assert ModelRouting.resolve_chain("openai/background-free") == [
             {:openrouter, "db-free-primary"},
             {:openrouter, "db-free-backup"}
           ]
  end
end
