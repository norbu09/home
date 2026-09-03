defmodule HomeWeb.MCP.MemoryServer do
  @moduledoc """
  Streamable-HTTP MCP server exposing home's Recollect memory
  (`Home.Memory`) to MCP-capable coding agents — Claude Code and Codex —
  alongside the opencode plugin's REST surface.

  Tools: `memory_remember`, `memory_search`, `memory_health`. Same
  semantics as `HomeWeb.MemoryController`, including the secret guard and
  the retrieval-only read path (search returns a context pack, never an
  LLM answer).

  Served at `/mcp` via `Hermes.Server.Transport.StreamableHTTP.Plug`,
  bearer-authed by `HomeWeb.Plugs.MemoryTokenAuth` with the same
  `memory/api_token` credential.
  """

  use Hermes.Server,
    name: "home-memory",
    version: "0.1.0",
    capabilities: [:tools]

  alias Hermes.Server.Response
  alias Home.Memory

  @impl true
  def init(_client_info, frame) do
    {:ok,
     frame
     |> register_tool("memory_remember",
       description:
         "Store a durable memory (a lesson, decision, operational fact) in home's local " <>
           "recollect memory. Use for things worth remembering across sessions. " <>
           "Never store secrets, tokens, or credentials — they are rejected server-side.",
       input_schema: %{
         content: {:required, :string},
         scope: :string,
         tags: {:list, :string}
       }
     )
     |> register_tool("memory_search",
       description:
         "Search home's local recollect agent memory (vector + graph, decay-managed). " <>
           "Use at the start of a task to recall relevant operational knowledge and past lessons.",
       input_schema: %{
         query: {:required, :string},
         scope: :string,
         limit: :integer
       }
     )
     |> register_tool("memory_health",
       description: "Report the status of home's memory store (embedding/extraction pipeline).",
       input_schema: %{}
     )}
  end

  @impl true
  def handle_tool_call("memory_remember", %{content: content} = args, frame) do
    opts =
      [scope: Map.get(args, :scope), tags: Map.get(args, :tags)]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case Memory.remember(content, opts) do
      {:ok, entry} ->
        {:reply, text("stored memory #{entry.id} (scope: #{scope_name(entry)})"), frame}

      {:error, :possible_secret} ->
        {:reply, text("rejected: the content looks like a credential — nothing was stored"),
         frame}

      {:error, reason} ->
        {:reply, text("store failed: #{inspect(reason)}"), frame}
    end
  end

  def handle_tool_call("memory_search", %{query: query} = args, frame) do
    opts =
      [scope: Map.get(args, :scope), limit: Map.get(args, :limit)]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case Memory.search(query, opts) do
      {:ok, %{text: text}} ->
        {:reply, text(text), frame}

      # ILIKE degraded mode returns {:text, markdown} tuples
      {:ok, results} when is_list(results) ->
        markdown =
          results
          |> Enum.map(fn
            {:text, md} -> md
            other -> inspect(other)
          end)
          |> Enum.join("\n")

        {:reply, text(markdown), frame}

      {:error, reason} ->
        {:reply, text("search failed: #{inspect(reason)}"), frame}
    end
  end

  def handle_tool_call("memory_health", _args, frame) do
    {:reply, text(Jason.encode!(Memory.health())), frame}
  end

  defp text(content), do: Response.tool() |> Response.text(content)

  defp scope_name(entry) do
    get_in(entry.metadata, ["scope"]) || "shared"
  end
end
