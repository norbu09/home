// Recollect memory plugin for opencode — talks to the `home` app's
// Recollect-backed memory API (HomeWeb.MemoryController).
//
// Install: copy this file to ~/.config/opencode/plugins/recollect.ts
// (opencode auto-loads plugins from that directory) and set
// RECOLLECT_API_TOKEN (or MEMORY_API_TOKEN) to the bearer token — either the
// MEMORY_API_TOKEN env var you gave home, or the `memory/api_token` entry in
// home's Crypto Keys UI.
//
// Retrieval-only by design: search returns a formatted context pack, no LLM
// completion on the read path, and NO auto-capture of session output —
// explicit tool calls only.
//
// Config:
//   RECOLLECT_URL        default http://127.0.0.1:4070
//   RECOLLECT_API_TOKEN  bearer token (falls back to MEMORY_API_TOKEN)
import { tool, type Plugin } from "@opencode-ai/plugin"

const BASE_URL = (process.env.RECOLLECT_URL || "http://127.0.0.1:4070").replace(/\/$/, "")
const TOKEN = process.env.RECOLLECT_API_TOKEN || process.env.MEMORY_API_TOKEN || ""

const TIMEOUT_MS = 30_000

async function call(path: string, body: Record<string, unknown>): Promise<string> {
  if (!TOKEN) {
    return "recollect memory is not configured: set RECOLLECT_API_TOKEN (home secret store: memory/api_token)"
  }

  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), TIMEOUT_MS)

  try {
    const response = await fetch(`${BASE_URL}${path}`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${TOKEN}`,
      },
      body: JSON.stringify(body),
      signal: controller.signal,
    })

    const data = await response.json().catch(() => ({}))

    if (!response.ok) {
      return `memory request failed (${response.status}): ${data.error ?? response.statusText}`
    }

    return data.text || JSON.stringify(data)
  } catch (error: any) {
    return `memory request failed: ${error?.message ?? error}`
  } finally {
    clearTimeout(timeout)
  }
}

export const RecollectPlugin: Plugin = async () => {
  return {
    tool: {
      recollect_remember: tool({
        description:
          "Store a durable memory (a lesson, decision, operational fact) in the local recollect memory. " +
          "Use for things worth remembering across sessions. Never store secrets, tokens, or credentials — " +
          "they are rejected server-side.",
        args: {
          content: tool.schema.string().describe("The memory content — one durable fact or lesson"),
          scope: tool.schema
            .string()
            .optional()
            .describe('Scope/namespace, e.g. "shared" (default) or a project name like "home"'),
          tags: tool.schema.array(tool.schema.string()).optional().describe("Optional tags"),
        },
        execute: async (args) => {
          return call("/api/memory/remember", {
            content: args.content,
            scope: args.scope,
            tags: args.tags,
            source: "opencode",
          })
        },
      }),

      recollect_search: tool({
        description:
          "Search the local recollect agent memory (vector + graph, decay-managed). " +
          "Use at the start of a task to recall relevant operational knowledge and past lessons.",
        args: {
          query: tool.schema.string().describe("What to recall"),
          scope: tool.schema
            .string()
            .optional()
            .describe('Scope to search, e.g. "shared" (default) or a project name'),
          limit: tool.schema.number().optional().describe("Max results (default 15)"),
        },
        execute: async (args) => {
          return call("/api/memory/search", {
            query: args.query,
            scope: args.scope,
            limit: args.limit,
          })
        },
      }),
    },
  }
}

export default RecollectPlugin
