defmodule HomeWeb.MemoryController do
  @moduledoc """
  HTTP surface for `Home.Memory`, consumed by the local opencode plugin
  (`~/.config/opencode/plugins/recollect.ts`). Bearer-token authed via
  the `memory/api_token` secret (or MEMORY_API_TOKEN env).

  Retrieval-only by design: search returns a formatted context pack, never an
  LLM-generated answer (no LLM on the memory read path).
  """
  use HomeWeb, :controller

  alias Home.Memory

  plug :authorize

  def remember(conn, %{"content" => content}) when is_binary(content) do
    opts = [
      scope: conn.body_params["scope"],
      entry_type: conn.body_params["entry_type"],
      tags: conn.body_params["tags"],
      source: conn.body_params["source"]
    ]

    case Memory.remember(content, compact(opts)) do
      {:ok, entry} ->
        json(conn, %{status: "ok", id: entry.id})

      {:error, :possible_secret} ->
        conn |> put_status(422) |> json(%{error: "content rejected: possible secret"})

      {:error, reason} ->
        conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  def remember(conn, _params) do
    conn |> put_status(400) |> json(%{error: "missing \"content\""})
  end

  def search(conn, %{"query" => query}) when is_binary(query) do
    opts = [
      scope: conn.body_params["scope"],
      tier: conn.body_params["tier"],
      limit: conn.body_params["limit"]
    ]

    case Memory.search(query, compact(opts)) do
      {:ok, result} ->
        json(conn, %{
          status: "ok",
          text: result.text,
          resolved_tier: result.resolved_tier,
          counts: result.counts
        })

      {:error, reason} ->
        conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  def search(conn, _params) do
    conn |> put_status(400) |> json(%{error: "missing \"query\""})
  end

  def health(conn, _params) do
    json(conn, %{status: "ok", memory: Memory.health()})
  end

  # ── Auth ────────────────────────────────────────────────────────────────

  defp authorize(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, expected} <- api_token(),
         true <- Plug.Crypto.secure_compare(token, expected) do
      conn
    else
      _ ->
        conn
        |> put_status(401)
        |> json(%{error: "unauthorized"})
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

  defp compact(opts), do: Enum.reject(opts, fn {_k, v} -> is_nil(v) end)
end
