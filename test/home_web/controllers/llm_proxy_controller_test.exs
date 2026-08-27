defmodule HomeWeb.LLMProxyControllerTest do
  use HomeWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  setup do
    old = Application.get_env(:home, :llm_proxy, [])

    Application.put_env(:home, :llm_proxy,
      provider_client: Home.LLMProxyTestClient,
      role_chains: %{
        "coder" => [{:zai, "glm-5.2"}, {:openrouter, "moonshotai/kimi-k3"}],
        "memory" => [
          {:openrouter, "openai/text-embedding-3-small"},
          {:ollama, "nomic-embed-text"}
        ]
      },
      model_groups: %{
        "glm-5.2" => [
          %{provider: :zai, model: "glm-5.2", order: 1, cost: %{input: 0.0, output: 0.0}},
          %{provider: :openrouter, model: "z-ai/glm-5.2", order: 2}
        ],
        "kimi-k2.7-coding" => [
          %{
            provider: :kimi_coding,
            model: "kimi-for-coding",
            order: 1,
            cost: %{input: 0.0, output: 0.0}
          },
          %{provider: :openrouter, model: "moonshotai/kimi-k2.7-code", order: 2}
        ],
        "background-free" => [
          %{
            provider: :openrouter,
            model: "z-ai/glm-5.2:free",
            order: 1,
            priority: 10,
            cost: %{input: 0.0, output: 0.0}
          },
          %{
            provider: :openrouter,
            model: "poolside/laguna-s-2.1:free",
            order: 1,
            priority: 20,
            cost: %{input: 0.0, output: 0.0}
          }
        ]
      },
      model_aliases: %{
        "openai/glm-5.2" => [{:zai, "glm-5.2"}, {:openrouter, "z-ai/glm-5.2"}],
        "cognee-chat" => "background-free",
        "openai/background-free" => "background-free",
        "text-embedding-3-small" => [{:openrouter, "openai/text-embedding-3-small"}]
      }
    )

    Home.LLMProxy.ProviderHealth.reset()
    Home.LLMProxy.UsageTracker.reset()
    on_exit(fn -> Application.put_env(:home, :llm_proxy, old) end)
    :ok
  end

  test "lists local role aliases and provider models", %{conn: conn} do
    conn = get(conn, ~p"/v1/models")
    assert %{"object" => "list", "data" => data} = json_response(conn, 200)
    assert Enum.any?(data, &(&1["id"] == "coder"))
    assert Enum.any?(data, &(&1["id"] == "glm-5.2"))
    assert Enum.any?(data, &(&1["id"] == "kimi-k2.7-coding"))
    assert Enum.any?(data, &(&1["id"] == "openai/gpt-4o"))
  end

  test "chat completions route through the configured failover chain", %{conn: conn} do
    conn =
      conn
      |> put_req_header("x-home-project", "ops_center")
      |> post(~p"/v1/chat/completions", %{
        "model" => "coder",
        "messages" => [%{"role" => "user", "content" => "hi"}]
      })

    assert %{
             "object" => "chat.completion",
             "model" => "coder",
             "choices" => [
               %{"message" => %{"content" => "served by openrouter/z-ai/glm-5.2"}}
             ]
           } = json_response(conn, 200)

    snapshot = Home.LLMProxy.UsageTracker.snapshot()
    usage = Enum.find(snapshot.projects, &(&1.id == "ops_center"))
    assert usage.calls == 1
    assert usage.input_tokens == 1
    assert usage.output_tokens == 4
    assert usage.cost_usd > 0
  end

  test "disabled projects are rejected before a provider call", %{conn: conn} do
    {:ok, _policy} =
      Home.LLMProxy.UsageTracker.set_project_policy("sandbox", %{enabled: false})

    conn =
      conn
      |> put_req_header("x-home-project", "sandbox")
      |> post(~p"/v1/chat/completions", %{
        "model" => "coder",
        "messages" => [%{"role" => "user", "content" => "hi"}]
      })

    assert %{"error" => %{"type" => "project_disabled"}} = json_response(conn, 403)
  end

  test "attributes usage from the per-project LLM header", %{conn: conn} do
    conn =
      conn
      |> put_req_header("x-llm-project", "kfos_agent")
      |> post(~p"/v1/chat/completions", %{
        "model" => "coder",
        "messages" => [%{"role" => "user", "content" => "hi"}]
      })

    assert json_response(conn, 200)
    usage = Enum.find(Home.LLMProxy.UsageTracker.snapshot().projects, &(&1.id == "kfos_agent"))
    assert usage.calls == 1
  end

  test "attributes tool-only proxy requests to the tools project", %{conn: conn} do
    conn =
      conn
      |> put_req_header("x-home-tool", "cognee")
      |> post(~p"/v1/chat/completions", %{
        "model" => "cognee-chat",
        "messages" => [%{"role" => "user", "content" => "extract graph"}]
      })

    assert json_response(conn, 200)
    snapshot = Home.LLMProxy.UsageTracker.snapshot()
    project = Enum.find(snapshot.projects, &(&1.id == "tools"))
    tool = Enum.find(snapshot.tools, &(&1.id == "cognee"))

    assert project.calls == 1
    assert tool.calls == 1
  end

  test "attributes a configured model alias when a tool cannot send headers", %{conn: conn} do
    conn =
      post(conn, ~p"/v1/chat/completions", %{
        "model" => "openai/background-free",
        "messages" => [%{"role" => "user", "content" => "extract graph"}]
      })

    assert json_response(conn, 200)
    details = Home.LLMProxy.UsageTracker.project_details("tools")
    tool = Enum.find(details.tools, &(&1.id == "cognee"))

    assert details.month.calls == 1
    assert tool.calls == 1
    assert tool.model_count == 1
  end

  test "chat completions route logical model groups and preserve public model name", %{conn: conn} do
    conn =
      conn
      |> put_req_header("x-home-project", "ops_center")
      |> post(~p"/v1/chat/completions", %{
        "model" => "kimi-k2.7-coding",
        "messages" => [%{"role" => "user", "content" => "hi"}]
      })

    assert %{
             "model" => "kimi-k2.7-coding",
             "choices" => [
               %{"message" => %{"content" => "served by kimi_coding/kimi-for-coding"}}
             ]
           } = json_response(conn, 200)
  end

  test "logs sanitized attribution diagnostics for proxy requests", %{conn: conn} do
    old_level = Logger.level()
    Logger.configure(level: :info)

    log =
      try do
        capture_log([level: :info], fn ->
          conn
          |> put_req_header("x-home-client", "opencode")
          |> put_req_header("x-home-project", "ops_center")
          |> put_req_header("x-home-tool", "opencode")
          |> put_req_header("x-home-directory", "/home/lenz/code/ops_center")
          |> put_req_header("x-home-session-id", "session-secret-ish")
          |> post(~p"/v1/chat/completions", %{
            "model" => "coder",
            "messages" => [%{"role" => "user", "content" => "do not log this"}],
            "stream" => false
          })
          |> json_response(200)
        end)
      after
        Logger.configure(level: old_level)
      end

    assert log =~ ~s("event":"llm_proxy_request")
    assert log =~ ~s("project":"ops_center")
    assert log =~ ~s("tool":"opencode")
    assert log =~ ~s("attribution_source":"header")
    assert log =~ ~s("attribution_source_detail":"x-home-project")
    assert log =~ ~s("tool_attribution_source":"header")
    assert log =~ ~s("tool_attribution_source_detail":"x-home-tool")
    assert log =~ ~s("x-home-client":"opencode")
    assert log =~ ~s("basename":"ops_center")
    refute log =~ "session-secret-ish"
    refute log =~ "do not log this"
  end

  test "warns when a proxy request is unattributed", %{conn: conn} do
    log =
      capture_log(fn ->
        conn
        |> post(~p"/v1/chat/completions", %{
          "model" => "coder",
          "messages" => [%{"role" => "user", "content" => "hi"}]
        })
        |> json_response(200)
      end)

    assert log =~ "[warning]"
    assert log =~ ~s("event":"llm_proxy_request")
    assert log =~ ~s("project":"unattributed")
    assert log =~ ~s("attribution_source":"fallback")
  end

  test "streaming completions announce failover and keep the requested model alias" do
    assert {:ok, _response} =
             Home.LLMProxy.stream_chat_completion(
               %{
                 "model" => "coder",
                 "messages" => [%{"role" => "user", "content" => "hi"}],
                 "stream" => true
               },
               fn event -> send(self(), {:stream_event, event}) end
             )

    events = collect_stream_events([])

    text =
      events |> Enum.map(&get_in(&1, [:choices, Access.at(0), :delta, :content])) |> Enum.join()

    assert text ==
             "bad first route\n\n[provider overloaded; switching to backup model]\n\nhello world"

    assert Enum.all?(events, &(&1.model == "coder"))
  end

  test "embeddings expose OpenAI-compatible response shape", %{conn: conn} do
    conn =
      post(conn, ~p"/v1/embeddings", %{
        "model" => "memory",
        "input" => ["one", "two"]
      })

    assert %{
             "object" => "list",
             "data" => [
               %{"object" => "embedding", "index" => 0, "embedding" => [0.1, 0.2, 0.3]},
               %{"object" => "embedding", "index" => 1, "embedding" => [0.1, 0.2, 0.3]}
             ]
           } = json_response(conn, 200)
  end

  test "cognee's configured model names resolve through compatibility aliases", %{conn: conn} do
    chat_conn =
      post(conn, ~p"/v1/chat/completions", %{
        "model" => "openai/glm-5.2",
        "messages" => [%{"role" => "user", "content" => "extract graph"}]
      })

    assert %{
             "model" => "openai/glm-5.2",
             "choices" => [
               %{"message" => %{"content" => "served by openrouter/z-ai/glm-5.2"}}
             ]
           } = json_response(chat_conn, 200)

    cognee_conn =
      post(conn, ~p"/v1/chat/completions", %{
        "model" => "cognee-chat",
        "messages" => [%{"role" => "user", "content" => "extract graph"}]
      })

    assert %{
             "model" => "cognee-chat",
             "choices" => [
               %{"message" => %{"content" => "served by openrouter/z-ai/glm-5.2:free"}}
             ]
           } = json_response(cognee_conn, 200)

    embedding_conn =
      post(conn, ~p"/v1/embeddings", %{
        "model" => "text-embedding-3-small",
        "input" => ["memory chunk"],
        "encoding_format" => "float"
      })

    assert %{
             "model" => "openrouter/openai/text-embedding-3-small",
             "data" => [%{"embedding" => [0.1, 0.2, 0.3]}]
           } = json_response(embedding_conn, 200)
  end

  defp collect_stream_events(events) do
    receive do
      {:stream_event, event} -> collect_stream_events([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end
end
