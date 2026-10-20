defmodule Mix.Tasks.Home.Memory.Import do
  @shortdoc "Import memory from Claude/Codex/OpenCode into local Recollect, scoped per project"

  @moduledoc """
  CLI wrapper around `Home.Memory.Importer.run/1` — bulk-imports local
  coding-agent memory into home's Recollect store, one scope per project.
  The pipeline (fetch, consent, project mapping) is the shared
  `Recollect.Learner.Harvest` (B-2165); consent is per user per machine
  (`~/.config/recollect/consent.json` — manage with
  `mix recollect.harvest --grant claude_code`, available in any checkout
  with the recollect dep).

  ## Examples

      mix home.memory.import --dry-run
      mix home.memory.import --source claude
      mix home.memory.import --source opencode --no-llm
      mix home.memory.import            # all available sources

  ## Options

    * `--source claude|codex|opencode|all` (default `all`)
    * `--dry-run` — print what would be stored, write nothing (no LLM calls)
    * `--no-llm`  — heuristic distillation for session notes
    * `--limit N` — cap notes per project batch
    * `--no-consent` — skip the per-agent consent gate
  """

  use Mix.Task

  alias Home.Memory.Importer

  @switches [
    source: :string,
    dry_run: :boolean,
    llm: :boolean,
    limit: :integer,
    consent: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, switches: @switches)
    source = Keyword.get(opts, :source, "all")
    dry_run? = Keyword.get(opts, :dry_run, false)

    unless dry_run? do
      Mix.Task.run("app.start")
    end

    sources =
      case source do
        "all" -> ["claude", "codex", "opencode"]
        s -> [s]
      end

    results =
      Importer.run(
        sources: sources,
        dry_run: dry_run?,
        use_llm: Keyword.get(opts, :llm, true),
        limit: Keyword.get(opts, :limit),
        consent: if(Keyword.get(opts, :consent, true), do: :enforce, else: :off),
        record: false
      )

    IO.puts("\n== Import summary ==")

    for {src, res} <- results do
      IO.puts(
        "  #{src}: fetched=#{res.fetched} stored=#{res.stored} skipped=#{res.skipped} projects=#{inspect(Map.keys(res.by_project))}"
      )
    end
  end
end
