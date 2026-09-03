# Home

Your local command hub for working with coding agents — a self-hosted Phoenix
app that sits on your machine (or home server) and gives you:

- **LLM Router** — an OpenAI-compatible proxy (`/v1/chat/completions`,
  `/v1/embeddings`) that routes across providers, tracks cost/latency per
  project and model, and enforces per-project quotas and pinning policies.
- **Agent Memory** — durable memory for your coding agents backed by
  [Recollect](https://github.com/kittyfromouterspace/recollect) (Postgres +
  pgvector). Agents store and recall lessons over a small HTTP API; a
  scheduled import picks up Claude Code / Codex / OpenCode history, scoped
  per project. Manage it from the **Memory** page and toggle the import on
  the **Settings** page.
- **Tactical Overview** — a dashboard that merges LLM usage, git activity,
  and memory signals into ranked "what was I working on" focus areas, plus
  personal goals.
- **Crypto Keys** — an encrypted store (Cloak/AES-GCM) for API keys and
  tokens, with fingerprinted display.

Everything is local-first: one Postgres database, no external dependencies
beyond the LLM providers you configure.

## Run with Docker (or Podman)

```sh
./install.sh
```

The installer detects your OS (macOS and the common Linux distro families)
and prints the exact packages to install if a container runtime or compose
provider is missing. It then generates all secrets, writes a mode-600 `.env`,
offers to install the [opencode plugin](#use-from-opencode), and starts the
stack.
Flags: `--yes` (no prompts), `--no-start` (config only), `--force`
(regenerate secrets), `--no-opencode`.

Prefer the manual route?

```sh
cp .env.example .env
# fill in the required secrets:
openssl rand -base64 48   # SECRET_KEY_BASE
openssl rand -base64 32   # CLOAK_KEY
openssl rand -base64 32   # TOKEN_SIGNING_SECRET

docker compose up --build -d
```

The app container runs database migrations on boot, then serves on
[http://localhost:4070](http://localhost:4070). Create your account at
`/register`.

| Variable | Required | Purpose |
| --- | --- | --- |
| `POSTGRES_PASSWORD` | yes | password for the bundled Postgres |
| `SECRET_KEY_BASE` | yes | Phoenix session/cookie signing |
| `CLOAK_KEY` | yes | encrypts the Crypto Keys store |
| `TOKEN_SIGNING_SECRET` | yes | AshAuthentication token signing |
| `PORT` | no (4070) | listen port |
| `PHX_HOST` | no (localhost) | public host for absolute URLs |
| `MEMORY_API_TOKEN` | no | bearer token for the memory API (else set `memory/api_token` in Crypto Keys) |

## Backups

The compose stack includes a `backup` sidecar that dumps the database with
`pg_dump` (custom format) into `./backups/` — daily by default, keeping 14
days of dumps (`BACKUP_INTERVAL_SECONDS`, `BACKUP_KEEP_DAYS` in `.env`).
The first dump runs at container start, so `./backups/` should contain a
`home-*.dump` file within a minute of `compose up`.

**Restore** into a running stack:

```sh
cat backups/home-YYYYMMDDTHHMMSSZ.dump | docker compose exec -T db \
  pg_restore -U postgres -d home_prod --clean --if-exists --no-owner --no-privileges
```

**Critical:** the dump alone is not a full backup. The Crypto Keys store is
encrypted with `CLOAK_KEY`, so **back up your `.env` (especially
`CLOAK_KEY`) separately** — without it, restored secrets are unrecoverable.
For real disaster recovery, also copy `./backups/` off the machine (rsync,
rclone, restic, …) — the sidecar only protects against database loss, not
host loss.

Manual one-off dump (works for non-container installs too, given a reachable
Postgres):

```sh
pg_dump --format=custom --no-owner --no-privileges "$DATABASE_URL" > home-$(date -u +%Y%m%dT%H%M%SZ).dump
```

### Importing your local agent history (optional)
The memory importer reads Claude Code / Codex / OpenCode stores from the
container's `$HOME`. To give it your real history, uncomment the read-only
volume mounts in `docker-compose.yml`, then enable the scheduled import on
the **Settings** page or run a one-off:

```sh
docker compose exec app bin/home eval "Home.Memory.Importer.run()"
```

## Use from opencode

`integrations/opencode/recollect.ts` is an
[opencode](https://opencode.ai) plugin that adds `recollect_remember` and
`recollect_search` tools backed by home's memory API.

```sh
cp integrations/opencode/recollect.ts ~/.config/opencode/plugins/
export RECOLLECT_API_TOKEN=...   # MEMORY_API_TOKEN from .env, or the memory/api_token secret
```

Retrieval-only by design: search returns a context pack (no LLM on the read
path) and nothing is captured automatically — memory writes are explicit tool
calls.

## Use from Claude Code

Claude Code talks to home over the **MCP endpoint** (`/mcp`, streamable HTTP,
same bearer token as the REST API — tools: `memory_remember`,
`memory_search`, `memory_health`):

```sh
claude mcp add --transport http home-memory http://127.0.0.1:4070/mcp \
  --header "Authorization: Bearer $RECOLLECT_API_TOKEN"
```

For automatic recall at the start of every session, install the SessionStart
hook (`./install.sh` offers to do this): it searches memory for the current
project and injects the result as session context.

```sh
mkdir -p ~/.claude/hooks
cp integrations/claude-code/session-memory.sh ~/.claude/hooks/
```

then register it in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "~/.claude/hooks/session-memory.sh" } ] }
    ]
  }
}
```

The hook reads `RECOLLECT_API_TOKEN` / `RECOLLECT_URL` from the environment
and exits silently when home is unreachable, so it never blocks a session.

## Use from Codex

Codex reaches the same MCP endpoint via its streamable-HTTP client
(`~/.codex/config.toml`):

```toml
experimental_use_rmcp_client = true

[mcp_servers.home_memory]
url = "http://127.0.0.1:4070/mcp"
bearer_token_env_var = "RECOLLECT_API_TOKEN"
```

Add a line to the project's `AGENTS.md` telling the agent to call
`memory_search` at task start and `memory_remember` for durable lessons —
Codex has no session-start hook, so the instruction is the recall trigger.

## Local setup (without Docker)

Prerequisites:

- **Elixir 1.19 / Erlang OTP 28** — e.g. via
  [asdf](https://asdf-vm.com): `asdf install` (`elixir --version` should
  report 1.19.x on OTP 28)
- **Postgres 16+ with the pgvector extension** — easiest via the container
  image: `docker run -d -p 5432:5432 -e POSTGRES_PASSWORD=postgres pgvector/pgvector:pg17`
  (or install `postgresql` + `pgvector` packages from your distro)

Then:

```sh
mix setup          # deps, assets, create + migrate the home_dev database
mix phx.server     # serves http://localhost:4070
```

`mix setup` migrates the database, and the migrations enable the `vector`
extension themselves — a stock Postgres superuser connection is enough.
Development uses the built-in `postgres/postgres` credentials against
`localhost` (edit `config/dev.exs` if yours differ) and a committed
dev-only encryption key, so no `.env` is needed locally.

First run: open [http://localhost:4070/register](http://localhost:4070/register)
and create your account. Optional follow-ups:

- **Memory API token** — the memory HTTP API needs a bearer token. Either
  `export MEMORY_API_TOKEN=...` before starting the server, or add it in the
  UI under **Crypto Keys** (service `memory`, key `api_token`).
- **LLM provider keys** (OpenRouter etc.) — add them under **Crypto Keys**
  to activate the router.
- **Scheduled memory import** — off by default; enable it on the
  **Settings** page, or run a one-off with `mix home.memory.import`
  (`--dry-run` to preview).

Useful commands:

```sh
mix test               # test suite (uses the home_test database)
mix precommit          # format + compile (warnings as errors) + tests — run before committing
mix home.memory.import --dry-run
iex -S mix phx.server  # server with a REPL
```
