#!/bin/sh
# Home installer: generates secrets, writes .env, optionally installs the
# opencode memory plugin, and starts the container stack.
#
#   ./install.sh                 interactive setup
#   ./install.sh --yes           accept all defaults (start the stack, skip prompts)
#   ./install.sh --no-start      write config only, don't start containers
#   ./install.sh --force         regenerate .env even if one exists
#   ./install.sh --no-opencode   skip the opencode plugin offer
set -eu

cd -P -- "$(dirname -- "$0")"

YES=0; START=1; FORCE=0; OPENCODE=1
for arg in "$@"; do
  case "$arg" in
    --yes|-y) YES=1 ;;
    --no-start) START=0 ;;
    --force) FORCE=1 ;;
    --no-opencode) OPENCODE=0 ;;
    --help|-h)
      grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -10
      exit 0 ;;
    *) echo "unknown flag: $arg (try --help)" >&2; exit 1 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s ==\n' "$*"; }

ask() { # ask <question> — true unless answered n/N; --yes always true
  [ "$YES" = 1 ] && return 0
  printf '%s [Y/n] ' "$1"
  read -r answer
  case "$answer" in n|N|no|No) return 1 ;; *) return 0 ;; esac
}

gen() { # gen <bytes> — url-safe-ish random secret
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 "$1"
  else
    head -c "$1" /dev/urandom | base64
  fi
}

# ── Prerequisites ─────────────────────────────────────────────────────────

step "Checking prerequisites"

# detect_os → prints an OS family: macos|debian|fedora|arch|suse|alpine|linux
detect_os() {
  case "$(uname -s)" in
    Darwin) echo "macos"; return ;;
  esac

  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    ids=$( . /etc/os-release; echo "${ID:-} ${ID_LIKE:-}" )
    case "$ids" in
      *debian*|*ubuntu*) echo "debian"; return ;;
      *fedora*|*rhel*|*centos*) echo "fedora"; return ;;
      *arch*) echo "arch"; return ;;
      *suse*) echo "suse"; return ;;
      *alpine*) echo "alpine"; return ;;
    esac
  fi
  echo "linux"
}

# install_hint — OS-specific instructions for getting a container runtime
# with compose support.
install_hint() {
  case "$(detect_os)" in
    macos)
      say "  Podman (recommended, free):"
      say "    brew install podman podman-compose"
      say "    podman machine init && podman machine start"
      say "  or Docker Desktop:  brew install --cask docker"
      say "  or colima:          brew install colima docker docker-compose && colima start" ;;
    debian)
      say "  Podman:   sudo apt install podman podman-compose"
      say "  Docker:   sudo apt install docker.io docker-compose-v2" ;;
    fedora)
      say "  Podman:   sudo dnf install podman podman-compose"
      say "  Docker:   sudo dnf install docker docker-compose && sudo systemctl enable --now docker" ;;
    arch)
      say "  Podman:   sudo pacman -S podman podman-compose"
      say "  Docker:   sudo pacman -S docker docker-compose && sudo systemctl enable --now docker" ;;
    suse)
      say "  Podman:   sudo zypper install podman podman-compose"
      say "  Docker:   sudo zypper install docker docker-compose && sudo systemctl enable --now docker" ;;
    alpine)
      say "  Podman:   apk add podman podman-compose"
      say "  Docker:   apk add docker docker-cli-compose" ;;
    *)
      say "  Install Docker (https://docs.docker.com/engine/install/) with the compose"
      say "  plugin, or Podman (https://podman.io) with podman-compose." ;;
  esac
}

RUNTIME=""
if command -v docker >/dev/null 2>&1; then RUNTIME="docker"
elif command -v podman >/dev/null 2>&1; then RUNTIME="podman"
fi

COMPOSE=""
if [ -n "$RUNTIME" ]; then
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE="docker compose"
  elif command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then
    COMPOSE="podman compose"
  elif command -v podman-compose >/dev/null 2>&1; then
    COMPOSE="podman-compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE="docker-compose"
  fi
fi

if [ -z "$RUNTIME" ]; then
  say "No container runtime (docker/podman) found on this $(detect_os) system."
  say "To install one:"
  install_hint
  if [ "$START" = 1 ]; then
    say ""
    say "Install a runtime, then re-run ./install.sh (or re-run with --no-start to"
    say "write the config only and start the stack yourself later)."
    exit 1
  fi
elif [ -z "$COMPOSE" ]; then
  say "Found $RUNTIME, but no compose provider."
  say "To add one:"
  install_hint
  if [ "$START" = 1 ]; then
    say ""
    say "Add a compose provider, then re-run ./install.sh."
    exit 1
  fi
fi

[ -n "$COMPOSE" ] && say "compose provider: $COMPOSE"

# ── .env ──────────────────────────────────────────────────────────────────

step "Writing .env"

if [ -f .env ] && [ "$FORCE" != 1 ]; then
  say ".env already exists — keeping it (use --force to regenerate)."
else
  [ -f .env ] && say "regenerating .env (--force)"

  POSTGRES_PASSWORD=$(gen 24 | tr -d '/+=' | head -c 32)
  MEMORY_API_TOKEN=$(gen 24 | tr -d '/+=' | head -c 32)

  umask 077
  cat > .env <<EOF
# Generated by install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Back this file up somewhere safe — CLOAK_KEY encrypts the Crypto Keys
# store; losing it makes the secrets in database backups unrecoverable.

POSTGRES_PASSWORD=$POSTGRES_PASSWORD
SECRET_KEY_BASE=$(gen 48)
CLOAK_KEY=$(gen 32)
TOKEN_SIGNING_SECRET=$(gen 32)
MEMORY_API_TOKEN=$MEMORY_API_TOKEN
PORT=4070
PHX_HOST=localhost
EOF
  say "wrote .env (mode 600) with fresh secrets"
fi

# shellcheck disable=SC1091
. ./.env

# ── Container stack ───────────────────────────────────────────────────────

if [ "$START" = 1 ]; then
  step "Starting the stack"
  say "running: $COMPOSE up -d --build (first build takes a few minutes)"
  $COMPOSE up -d --build
  say ""
  say "home is starting on http://localhost:${PORT:-4070}"
  say "migrations run automatically on boot; watch with: $COMPOSE logs -f app"
fi

# ── opencode plugin ───────────────────────────────────────────────────────

if [ "$OPENCODE" = 1 ] && [ -d "$HOME/.config/opencode" ]; then
  step "opencode plugin"
  if ask "Install the recollect memory plugin to ~/.config/opencode/plugins/?"; then
    mkdir -p "$HOME/.config/opencode/plugins"
    cp integrations/opencode/recollect.ts "$HOME/.config/opencode/plugins/recollect.ts"
    say "installed ~/.config/opencode/plugins/recollect.ts"

    env_file="$HOME/.config/opencode/.env"
    if grep -q '^RECOLLECT_API_TOKEN=' "$env_file" 2>/dev/null; then
      say "$env_file already sets RECOLLECT_API_TOKEN — leaving it"
    else
      printf 'RECOLLECT_API_TOKEN=%s\n' "${MEMORY_API_TOKEN:-}" >> "$env_file"
      say "wrote RECOLLECT_API_TOKEN to $env_file"
    fi
  fi
fi

# ── Done ──────────────────────────────────────────────────────────────────

step "Done"
say "Next steps:"
say "  1. Open http://localhost:${PORT:-4070}/register and create your account"
say "  2. Add LLM provider keys (OpenRouter, ...) under Crypto Keys"
say "  3. Enable the scheduled memory import on the Settings page"
if [ "$START" = 0 ]; then
  say ""
  say "Start the stack later with: ${COMPOSE:-docker compose} up -d --build"
fi
