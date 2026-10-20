defmodule Home.Memory.Importer do
  @moduledoc """
  Imports local coding-agent memory into home's Recollect store, one scope
  per project.

  Since B-2165 this is a thin home-specific shell over the shared harvest
  pipeline (`Recollect.Learner.Harvest`): fetch, per-agent consent
  (`Recollect.Learner.Consent` — grants live in
  `~/.config/recollect/consent.json`, manage with
  `mix recollect.harvest --grant claude_code`), and project mapping
  (`Recollect.Learner.ProjectMapping`) live in recollect. What stays here is
  home's store semantics:

    * fetch   — recollect's coding-agent providers (Claude Code, Codex,
      OpenCode), reading their local session/memory stores
    * extract — `Recollect.Learner.CodingAgent.extract/1` turns events into
      notes (recollect's harvest does this; the result is grouped per scope)
    * distill — codex/opencode session notes go through
      `Recollect.Sleep.distill/2` (LLM via the local proxy, or heuristic with
      `use_llm: false`)
    * store   — `Home.Memory.remember/2` with a deterministic
      `import:<agent>:<scope>:<hash>` source_id, so re-runs are idempotent

  Claude's curated memory files (`memory/*.md`, `CLAUDE.md`) are stored
  directly: the curated files ARE the distillation, so no LLM pass.

  The scheduler (`Home.Memory.ImportScheduler`) and the `/memory` UI call
  `run/1`; each run's summary is recorded in `Home.Settings` under
  `memory_import.last_run`. Per-source failures are contained: one agent's
  fetch crashing does not abort the others' import.
  """

  alias Home.Memory
  alias Home.Settings
  alias Recollect.Learner.Harvest
  alias Recollect.Learner.ProjectMapping

  require Logger

  @sources ["claude", "codex", "opencode"]
  @provider_names %{"claude" => :claude_code, "codex" => :codex, "opencode" => :opencode}
  # Curated memory + CLAUDE.md only — session transcripts are noise here.
  @curated_sources [:memory_file, :claude_md]
  @last_run_key "memory_import.last_run"

  @doc """
  Run an import pass.

  ## Options

    * `:sources` — subset of `["claude", "codex", "opencode"]` (default all)
    * `:dry_run` — preview grouping without distilling or storing (no LLM calls)
    * `:use_llm` — LLM distillation for session notes (default true)
    * `:limit`   — cap notes per project batch
    * `:record`  — write the run summary to `Home.Settings` (default true)
    * `:consent` — `:enforce` (default; only consented agents are read) or `:off`

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

    ProjectMapping.scope_for_key(project)
  end

  # ── Per-source import ───────────────────────────────────────────────────

  defp import_source(source, opts) do
    provider = Map.fetch!(@provider_names, source)

    result =
      try do
        {:ok,
         Harvest.run(
           all_sessions: true,
           agents: [provider],
           sink: :collect,
           record: false,
           consent: Keyword.get(opts, :consent, :enforce),
           log: fn msg -> Logger.info("memory import: #{msg}") end
         )}
      rescue
        e ->
          Logger.warning("memory import: #{source} fetch failed: #{Exception.message(e)}")
          {:error, e}
      end

    case result do
      {:ok, %{records: records}} ->
        records
        |> filter_source(source)
        |> store_notes(source, opts)

      {:error, _} ->
        initial()
    end
  end

  defp filter_source(records, "claude"),
    do: Enum.filter(records, &(&1.source in @curated_sources))

  defp filter_source(records, _source), do: records

  defp initial, do: %{fetched: 0, stored: 0, skipped: 0, by_project: %{}}

  # ── Store: group by project, optionally distill, dedup by source_id ────

  defp store_notes(records, agent, opts) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    # Claude's curated files skip distillation; codex/opencode session notes
    # get the LLM pass.
    distill? = agent != "claude"
    use_llm? = Keyword.get(opts, :use_llm, true)
    limit = Keyword.get(opts, :limit)

    records
    |> Enum.group_by(&project_scope/1)
    |> Enum.reduce(initial(), fn {scope, scope_records}, acc ->
      scope_records = if limit, do: Enum.take(scope_records, limit), else: scope_records

      items =
        cond do
          # Dry-run never calls the LLM and never distills: group raw notes.
          dry_run? -> scope_records
          distill? -> distill(scope_records, scope, use_llm?)
          true -> scope_records
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
        | fetched: acc.fetched + length(scope_records),
          stored: acc.stored + stored,
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
end
