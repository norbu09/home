defmodule HomeWeb.MCP.MemoryServerTest do
  use HomeWeb.ConnCase, async: false

  alias Home.Memory

  setup do
    System.put_env("MEMORY_API_TOKEN", "test-memory-token")

    on_exit(fn -> System.delete_env("MEMORY_API_TOKEN") end)

    %{token: "test-memory-token"}
  end

  defp mcp_post(conn, token, payload) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("content-type", "application/json")
    |> post(~p"/mcp", Jason.encode!(payload))
  end

  defp initialize(conn, token) do
    conn =
      mcp_post(conn, token, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-03-26",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "0.1"}
        }
      })

    session_id =
      conn
      |> get_resp_header("mcp-session-id")
      |> List.first()

    conn = recycle(conn)

    mcp_post(
      put_req_header(conn, "mcp-session-id", session_id),
      token,
      %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
    )

    session_id
  end

  test "rejects unauthenticated requests", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        ~p"/mcp",
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => %{}})
      )

    assert json_response(conn, 401)
  end

  test "initialize handshake reports the memory server", %{conn: conn, token: token} do
    conn =
      mcp_post(conn, token, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-03-26",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "0.1"}
        }
      })

    body = json_response(conn, 200)
    assert body["result"]["serverInfo"]["name"] == "home-memory"
    assert body["result"]["capabilities"]["tools"]
  end

  test "tools/list and memory_remember + memory_search round-trip", %{conn: conn, token: token} do
    session_id = initialize(conn, token)

    conn =
      recycle(conn)
      |> put_req_header("mcp-session-id", session_id)
      |> mcp_post(token, %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})

    tools = json_response(conn, 200)["result"]["tools"]
    names = Enum.map(tools, & &1["name"])
    assert "memory_remember" in names
    assert "memory_search" in names
    assert "memory_health" in names

    conn =
      recycle(conn)
      |> put_req_header("mcp-session-id", session_id)
      |> mcp_post(token, %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools/call",
        "params" => %{
          "name" => "memory_remember",
          "arguments" => %{"content" => "mcp round-trip probe", "scope" => "home"}
        }
      })

    result = json_response(conn, 200)["result"]
    assert result["isError"] == false
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "stored memory"

    # Stored via the same facade — verify with the facade directly.
    assert {:ok, results} = Memory.search("mcp round-trip probe", scope: "home")

    assert Enum.any?(results, fn
             %{content: content} -> content =~ "mcp round-trip probe"
             {:text, md} -> md =~ "mcp round-trip probe"
           end)
  end

  test "memory_remember applies the secret guard over MCP", %{conn: conn, token: token} do
    session_id = initialize(conn, token)

    conn =
      recycle(conn)
      |> put_req_header("mcp-session-id", session_id)
      |> mcp_post(token, %{
        "jsonrpc" => "2.0",
        "id" => 4,
        "method" => "tools/call",
        "params" => %{
          "name" => "memory_remember",
          "arguments" => %{"content" => "db password = hunter2hunter2hunter2hunter2"}
        }
      })

    result = json_response(conn, 200)["result"]
    assert [%{"type" => "text", "text" => text}] = result["content"]
    assert text =~ "rejected"
  end
end
