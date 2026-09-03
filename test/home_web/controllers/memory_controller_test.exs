defmodule HomeWeb.MemoryControllerTest do
  use HomeWeb.ConnCase, async: false

  setup do
    System.put_env("MEMORY_API_TOKEN", "test-memory-token")

    on_exit(fn -> System.delete_env("MEMORY_API_TOKEN") end)

    %{token: "test-memory-token"}
  end

  defp authed(conn, token) do
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  describe "auth" do
    test "rejects missing token", %{conn: conn} do
      conn = post(conn, ~p"/api/memory/remember", %{content: "hello"})
      assert json_response(conn, 401)
    end

    test "rejects wrong token", %{conn: conn} do
      conn =
        conn
        |> authed("wrong")
        |> post(~p"/api/memory/remember", %{content: "hello"})

      assert json_response(conn, 401)
    end
  end

  describe "remember + search round-trip" do
    test "stores a memory and finds it again", %{conn: conn, token: token} do
      conn1 =
        conn
        |> authed(token)
        |> post(~p"/api/memory/remember", %{
          content: "The home LLM proxy listens on port 4070.",
          scope: "home"
        })

      assert %{"status" => "ok", "id" => _id} = json_response(conn1, 200)

      conn2 =
        build_conn()
        |> authed(token)
        |> post(~p"/api/memory/search", %{query: "LLM proxy port", scope: "home"})

      assert %{"status" => "ok", "counts" => counts} = json_response(conn2, 200)
      assert is_map(counts)
    end

    test "rejects secret-shaped content", %{conn: conn, token: token} do
      conn =
        conn
        |> authed(token)
        |> post(~p"/api/memory/remember", %{
          content:
            "-----BEGIN OPENSSH PRIVATE KEY-----\nabc123\n-----END OPENSSH PRIVATE KEY-----"
        })

      assert %{"error" => "content rejected: possible secret"} = json_response(conn, 422)
    end

    test "remember requires content", %{conn: conn, token: token} do
      conn = conn |> authed(token) |> post(~p"/api/memory/remember", %{})
      assert json_response(conn, 400)
    end
  end

  describe "health" do
    test "returns memory subsystem status", %{conn: conn, token: token} do
      conn = conn |> authed(token) |> get(~p"/api/memory/health")

      assert %{"status" => "ok", "memory" => memory} = json_response(conn, 200)
      assert Map.has_key?(memory, "pipeline")
      assert memory["embedding"] in ["enabled", "disabled"]
    end
  end
end
