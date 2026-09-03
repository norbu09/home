defmodule Home.Memory do
  @moduledoc """
  Local agent memory for the `home` hub, backed by Recollect (Postgres +
  pgvector), replacing the retired local cognee instance.

  Plain library integration: this facade is the only place that knows about
  scopes, the shared owner id and the secret guard. The HTTP surface for
  opencode lives in `HomeWeb.MemoryController`.

  Scopes are namespaced strings (`"shared"` default, or a project name like
  `"home"`), hashed to deterministic UUIDs — Recollect stores `scope_id` as a
  binary_id, and deterministic hashing keeps the human scope recoverable in
  `metadata.scope`.

  Degrades gracefully: without an OpenRouter key, writes still work and
  search falls back to Recollect's non-vector path; without a reachable local
  LLM, graph extraction is skipped (chunks + entries still stored).
  """

  alias Home.Secrets.Store
  alias Recollect.Search.ContextFormatter

  require Logger

  @default_scope "shared"

  # ── Facade ──────────────────────────────────────────────────────────────

  @doc """
  Store a durable memory. Returns `{:ok, entry}` or `{:error, reason}`
  (`:possible_secret` when the content looks like a credential).
  """
  def remember(content, opts \\ []) when is_binary(content) do
    if possible_secret?(content) do
      {:error, :possible_secret}
    else
      scope = Keyword.get(opts, :scope, @default_scope)
      source = normalize_source(Keyword.get(opts, :source, "agent"))

      Recollect.Knowledge.remember(content,
        entry_type: Keyword.get(opts, :entry_type, "note"),
        owner_id: owner_uuid(),
        scope_id: scope_uuid(scope),
        source: source,
        source_id: Keyword.get(opts, :source_id),
        tags: Keyword.get(opts, :tags, []),
        metadata: %{"scope" => scope, "source" => Keyword.get(opts, :source, "opencode")}
      )
    end
  end

  # Recollect's Entry.source enum only allows agent/system/user — callers
  # pass their agent name ("opencode", "claude", ...), which we fold into
  # "agent"; the original name survives in metadata.source.
  defp normalize_source(source) when source in ["agent", "system", "user"], do: source
  defp normalize_source(_other), do: "agent"

  @doc "True when an entry with this source_id already exists in the scope."
  def source_exists?(scope, source_id) do
    import Ecto.Query

    Home.Repo.exists?(
      from(e in Recollect.Schema.Entry,
        where: e.scope_id == ^scope_uuid(scope) and e.source_id == ^source_id
      )
    )
  end

  @doc """
  Search memory. Returns `{:ok, %{text: formatted_context_pack, counts: ...}}`.
  Tier defaults to `:auto` (Recollect's heuristic routing).

  Without embedding credentials, Recollect's vector search is unavailable —
  falls back to a scoped ILIKE over entries (same degraded mode kfos_agent
  uses).
  """
  def search(query, opts \\ []) when is_binary(query) do
    scope = Keyword.get(opts, :scope, @default_scope)

    if Recollect.Config.embedding_enabled?() do
      do_search(query, scope, opts)
    else
      ilike_fallback(query, scope, opts)
    end
  end

  defp do_search(query, scope, opts) do
    search_opts = [
      owner_id: owner_uuid(),
      scope_id: scope_uuid(scope),
      tier: Keyword.get(opts, :tier, :auto),
      limit: Keyword.get(opts, :limit, 15)
    ]

    case Recollect.Search.search(query, search_opts) do
      {:ok, pack} ->
        {:ok,
         %{
           text: ContextFormatter.format(pack),
           resolved_tier: Map.get(pack, :resolved_tier),
           counts: %{
             chunks: length(pack.chunks),
             entries: length(pack.entries),
             related_entries: length(pack.related_entries || []),
             entities: length(pack.entities || [])
           }
         }}

      {:error, _} = error ->
        error
    end
  end

  defp ilike_fallback(query, scope, opts) do
    import Ecto.Query

    limit = Keyword.get(opts, :limit, 15)
    pattern = "%" <> String.replace(query, ~r/[%_]/, "") <> "%"

    entries =
      Home.Repo.all(
        from e in Recollect.Schema.Entry,
          where: e.scope_id == ^scope_uuid(scope) and ilike(e.content, ^pattern),
          order_by: [desc: e.inserted_at],
          limit: ^limit,
          select: %{content: e.content, inserted_at: e.inserted_at}
      )

    text =
      case entries do
        [] ->
          "No relevant memories (embeddings disabled; keyword fallback)."

        entries ->
          "## Relevant Memories (keyword fallback)\n" <>
            Enum.map_join(entries, "\n", &("- " <> &1.content))
      end

    {:ok, %{text: text, resolved_tier: :fallback, counts: %{entries: length(entries)}}}
  end

  @doc "Pipeline + configuration health, for the /api/memory/health endpoint."
  def health do
    %{
      embedding: if(Recollect.Config.embedding_enabled?(), do: :enabled, else: :disabled),
      extraction: if(Recollect.Config.extraction_enabled?(), do: :enabled, else: :disabled),
      pipeline: Recollect.Pipeline.health()
    }
  end

  # ── Recollect config callbacks (see config/config.exs) ─────────────────

  @doc "Embedding credentials from the Cloak secret store (llm/OPENROUTER_API_KEY)."
  def embedding_credentials do
    case Store.get("llm", "OPENROUTER_API_KEY") do
      {:ok, key} ->
        %{api_key: key, model: "openai/text-embedding-3-small", dimensions: 1536}

      _ ->
        :disabled
    end
  end

  @doc """
  Extraction LLM via home's own local proxy (:4070, `memory` model).
  Contract: `(messages, opts) -> {:ok, text} | {:error, reason}`.
  """
  def llm_fn(messages, opts) do
    body = %{
      model: "memory",
      messages: messages,
      max_tokens: Keyword.get(opts, :max_tokens, 2000),
      temperature: 0
    }

    case Req.post("http://127.0.0.1:4070/v1/chat/completions",
           json: body,
           receive_timeout: 120_000,
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => text}} | _]}}} ->
        {:ok, text}

      {:ok, %{status: status, body: body}} ->
        {:error, {:llm_proxy, status, inspect(body) |> String.slice(0, 200)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Internals ───────────────────────────────────────────────────────────

  @doc "Deterministic UUID for a human scope name (md5-based, UUIDv3-style)."
  def scope_uuid(scope) when is_binary(scope) do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.hash(:md5, scope)
    {:ok, uuid} = Ecto.UUID.load(<<a::48, 3::4, b::12, 2::2, c::62>>)
    uuid
  end

  @doc "Single fixed owner for everything home writes."
  def owner_uuid, do: scope_uuid("home")

  @secret_patterns [
    ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/,
    ~r/(?i)(api[_-]?key|password|secret|token)\s*[:=]\s*["']?[A-Za-z0-9_\-\.\+\/=]{16,}/,
    ~r/sk-[A-Za-z0-9_\-]{20,}/
  ]

  defp possible_secret?(content) do
    Enum.any?(@secret_patterns, &Regex.match?(&1, content))
  end
end
