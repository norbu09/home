defmodule Home.Memory.Importer do
  @moduledoc """
  Imports local coding-agent memory into home's Recollect store, one scope
  per project. Orchestrates the existing recollect learning pipeline:

    * fetch   — `Recollect.Learner.CodingAgent` providers (Claude Code,
      Codex, OpenCode), reading their local session/memory stores
    * extract — each provider's `extract/1` turns events into notes
    * distill — session notes go through `Recollect.Sleep.distill/2` (LLM
      via the local proxy, or heuristic with `use_llm: false`)
    * store   — `Home.Memory.remember/2` with a deterministic
      `import:<agent>:<scope>:<hash>` source_id, so re-runs are idempotent

  Claude's curated memory files (`memory/*.md`, `CLAUDE.md`) are stored
  directly: the curated files ARE the distillation, so no LLM pass.

  The scheduler (`Home.Memory.ImportScheduler`) and the `/memory` UI call
  `run/1`; each run's summary is recorded in `Home.Settings` under
  `memory_import.last_run`.
  """

  alias Home.Memory
  alias Home.Settings
  alias Recollect.Learner.CodingAgent

  require Logger

  @sources ["claude", "codex", "opencode"]
  @last_run_key "memory_import.last_run"

  @doc """
  Run an import pass.

  ## Options

    * `:sources` — subset of `["claude", "codex", "opencode"]` (default all)
    * `:dry_run` — preview grouping without distilling or storing (no LLM calls)
    * `:use_llm` — LLM distillation for session notes (default true)
    * `:limit`   — cap notes per project batch
    * `:record`  — write the run summary to `Home.Settings` (default true)

  Returns a map `%{source => %{fetched:, stored:, skipped:, by_project:}}`.
  """
  def run(opts \\ []) do
    sources = Keyword.get(opts, :sources, @sources)
    dry_run? = Keyword.get(opts, :dry_run, false)

    results = Map.new(sources, &{&1, import_source(&1, opts)})

    if Keyword.get(opts, :record, true) and not dry_run? do
      Settings.put_json(@last_run_key, %{
        at: DateTime.utc_now(),
        results: results
      })
    end

    results
  end

  @doc "The most recent recorded run summary, or nil."
  def last_run, do: Settings.get_json(@last_run_key)

  @doc """
  Resolve a note's project key (provider-specific encodings like
  `-home-lenz-code-ops-center` or `/home/lenz/code/ops_center`) to the
  scope name, matching against real checkouts under `~/code`.
  """
  def project_scope(note) do
    project =
      get_in(note, [:metadata, :project]) ||
        get_in(note, [:metadata, "project"]) ||
        Map.get(note, :project)

    case project do
      nil ->
        "shared"

      p when is_binary(p) ->
        p
        |> String.trim_leading("-")
        |> String.replace("-", "/")
        |> String.split("/", trim: true)
        |> resolve_project_name()

      other ->
        to_string(other)
    end
  end

  # ── Per-source import ───────────────────────────────────────────────────

  defp import_source("claude", opts) do
    provider = CodingAgent.ClaudeCode

    # Curated memory + CLAUDE.md only — session transcripts are noise here.
    notes =
      provider
      |> safe_fetch()
      |> Enum.filter(&(&1.source in [:memory_file, :claude_md]))
      |> extract_all(provider)

    store_notes(notes, "claude", Keyword.put(opts, :distill, false))
  end

  defp import_source(source, opts) when source in ["codex", "opencode"] do
    provider =
      %{codex: CodingAgent.Codex, opencode: CodingAgent.OpenCode}[String.to_existing_atom(source)]

    notes = provider |> safe_fetch() |> extract_all(provider)

    store_notes(notes, source, Keyword.put(opts, :distill, true))
  end

  defp safe_fetch(provider) do
    config = %{data_paths: provider.default_data_paths()}

    if provider.available?(config) do
      provider.fetch_events(config, [])
    else
      Logger.info("memory import: #{provider.agent_name()} not available, skipping")
      []
    end
  rescue
    e ->
      Logger.warning(
        "memory import: #{provider.agent_name()} fetch failed: #{Exception.message(e)}"
      )

      []
  end

  defp extract_all(events, provider) do
    Enum.flat_map(events, fn event ->
      case provider.extract(event) do
        {:ok, note} -> [note]
        {:skip, _} -> []
      end
    end)
  end

  # ── Store: group by project, optionally distill, dedup by source_id ────

  defp store_notes(notes, agent, opts) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    distill? = Keyword.get(opts, :distill, false)
    use_llm? = Keyword.get(opts, :use_llm, true)
    limit = Keyword.get(opts, :limit)

    initial = %{fetched: length(notes), stored: 0, skipped: 0, by_project: %{}}

    notes
    |> Enum.group_by(&project_scope/1)
    |> Enum.reduce(initial, fn {scope, project_notes}, acc ->
      project_notes = if limit, do: Enum.take(project_notes, limit), else: project_notes

      items =
        cond do
          # Dry-run never calls the LLM and never distills: group raw notes.
          dry_run? -> project_notes
          distill? -> distill(project_notes, scope, use_llm?)
          true -> project_notes
        end

      {stored, skipped} =
        Enum.reduce(items, {0, 0}, fn item, {st, sk} ->
          source_id = source_id_for(agent, scope, item)

          if dry_run? do
            {st, sk + 1}
          else
            case store_once(scope, item, source_id) do
              :stored ->
                {st + 1, sk}

              :duplicate ->
                {st, sk + 1}

              {:error, reason} ->
                Logger.warning("memory import: store failed (#{scope}): #{inspect(reason)}")
                {st, sk + 1}
            end
          end
        end)

      %{
        acc
        | stored: acc.stored + stored,
          skipped: acc.skipped + skipped,
          by_project: Map.put(acc.by_project, scope, stored)
      }
    end)
  end

  defp distill(notes, scope, use_llm?) do
    candidates = Enum.map(notes, fn n -> %{content: n.content} end)

    case Recollect.Sleep.distill(candidates, use_llm: use_llm?, llm_fn: &Memory.llm_fn/2) do
      [] ->
        # Distillation produced nothing — keep the raw notes rather than
        # dropping the project silently.
        notes

      items ->
        Logger.info(
          "memory import: #{scope} distilled #{length(notes)} notes → #{length(items)} items"
        )

        items
    end
  end

  defp store_once(scope, item, source_id) do
    if Memory.source_exists?(scope, source_id) do
      :duplicate
    else
      case Memory.remember(item.content,
             scope: scope,
             entry_type: Map.get(item, :entry_type, "note"),
             tags: Map.get(item, :tags, []),
             source: "agent",
             source_id: source_id
           ) do
        {:ok, _entry} -> :stored
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp source_id_for(agent, scope, item) do
    hash =
      :crypto.hash(:sha256, item.content)
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 16)

    "import:#{agent}:#{scope}:#{hash}"
  end

  # ── Project → scope mapping ─────────────────────────────────────────────

  @code_root Path.expand("~/code")

  defp resolve_project_name([]), do: "shared"
  defp resolve_project_name(["unknown"]), do: "shared"

  defp resolve_project_name(segments) do
    # Try the longest trailing suffix that matches a real checkout, with
    # dashes mapped to underscores ("mark", "mesh" → "mark_mesh").
    1..min(3, length(segments))
    |> Enum.map(fn n -> segments |> Enum.take(-n) |> Enum.join("_") end)
    |> Enum.find(fn candidate -> File.dir?(Path.join(@code_root, candidate)) end)
    |> case do
      nil -> List.last(segments)
      name -> name
    end
  end
end
