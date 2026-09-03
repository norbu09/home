#!/bin/sh
# Claude Code SessionStart hook: inject relevant memories from home's
# Recollect store into the session context.
#
# Registration (~/.claude/settings.json):
#
#   {
#     "hooks": {
#       "SessionStart": [
#         { "hooks": [ { "type": "command", "command": "~/.claude/hooks/session-memory.sh" } ] }
#       ]
#     }
#   }
#
# Config: RECOLLECT_URL (default http://127.0.0.1:4070) and
# RECOLLECT_API_TOKEN (or MEMORY_API_TOKEN). Fails silently (exit 0) so a
# down/unreachable home never blocks a session start.
set -u

command -v curl >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

TOKEN="${RECOLLECT_API_TOKEN:-${MEMORY_API_TOKEN:-}}"
[ -n "$TOKEN" ] || exit 0

BASE_URL="${RECOLLECT_URL:-http://127.0.0.1:4070}"

# Hook payload on stdin: {"cwd": "...", "source": "startup|resume|clear", ...}
payload=$(cat)
cwd=$(printf '%s' "$payload" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("cwd", ""))' 2>/dev/null || true)
[ -n "$cwd" ] || exit 0

# Project scope = checkout dir name (matches Home.Memory.Importer's mapping).
scope=$(basename "$cwd" | tr 'A-Z' 'a-z')

query="recent lessons, decisions, gotchas and operational knowledge for the $scope project"

body=$(python3 -c '
import json, sys
scope, query = sys.argv[1], sys.argv[2]
print(json.dumps({"query": query, "scope": scope, "limit": 8}))
' "$scope" "$query")

response=$(curl -sf --max-time 5 -X POST "$BASE_URL/api/memory/search" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$body" 2>/dev/null) || exit 0

printf '%s' "$response" | python3 -c '
import json, sys
text = json.load(sys.stdin).get("text", "").strip()
if text and "No relevant" not in text:
    print("## Agent memory (home recollect)\n")
    print(text)
' 2>/dev/null || true

exit 0
