defmodule HomeWeb.Plugs.MemoryTokenAuth do
  @moduledoc """
  Bearer-token auth for the memory surfaces (REST `/api/memory/*` and the
  MCP endpoint). The token is the `memory/api_token` secret from the Crypto
  Keys store, or the `MEMORY_API_TOKEN` env var as a fallback.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, expected} <- api_token(),
         true <- Plug.Crypto.secure_compare(token, expected) do
      conn
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
        |> halt()
    end
  end

  defp api_token do
    case Home.Secrets.Store.get("memory", "api_token") do
      {:ok, token} ->
        {:ok, token}

      _ ->
        case System.get_env("MEMORY_API_TOKEN") do
          token when is_binary(token) and token != "" -> {:ok, token}
          _ -> :error
        end
    end
  end
end
