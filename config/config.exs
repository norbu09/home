# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :home, :llm_usage_sweep_interval_ms, 60_000

config :home, :cognee_insights,
  enabled: true,
  endpoint: "http://127.0.0.1:8000",
  ui_endpoint: "http://localhost:3000",
  interval_ms: 15 * 60 * 1_000,
  initial_delay_ms: 2_000,
  request_timeout_ms: 15_000

config :home, :git_activity,
  root: "/home/lenz/code",
  lookback_days: 7,
  commits_per_project: 5

config :home, :llm_model_route_refresher,
  enabled: true,
  interval_ms: 24 * 60 * 60 * 1000,
  initial_delay_ms: 15_000,
  groups: ["background-free", "free-coding", "openrouter-free-coding"]

config :mime,
  extensions: %{"json" => "application/vnd.api+json"},
  types: %{"application/vnd.api+json" => ["json"]}

config :ash_json_api,
  show_public_calculations_when_loaded?: false,
  authorize_update_destroy_with_error?: true

# These enable behaviors that will become the default in the next major
# version of Ash. Setting them now opts your application into the new
# behavior and ensures a seamless upgrade. See the backwards compatibility
# guide for an explanation of each setting:
# https://hexdocs.pm/ash/backwards-compatibility-config.html
config :ash,
  allow_forbidden_field_for_relationships_by_default: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true,
  redact_sensitive_values_in_errors?: true,
  many_to_many_destroy_destination_on_match?: true,
  known_types: [AshPostgres.Timestamptz, AshPostgres.TimestamptzUsec]

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :authentication,
        :token,
        :user_identity,
        :postgres,
        :json_api,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [
      section_order: [:json_api, :resources, :policies, :authorization, :domain, :execution]
    ]
  ]

config :home,
  ecto_repos: [Home.Repo],
  generators: [timestamp_type: :utc_datetime],
  ash_domains: [Home.Accounts]

config :home, Home.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1", key: Base.decode64!("tw0wUg3IY5rglYDyudVy90TyAbFUHsDGQuxsQsNWRHk=")}
  ]

config :agentic,
  providers: [
    Agentic.LLM.Provider.Anthropic,
    Agentic.LLM.Provider.OpenAI,
    Agentic.LLM.Provider.OpenRouter,
    Agentic.LLM.Provider.Groq,
    Agentic.LLM.Provider.Ollama,
    Agentic.LLM.Provider.Zai,
    Agentic.LLM.Provider.Moonshot,
    Agentic.LLM.Provider.KimiCoding
  ]

free_openrouter_coding_routes = [
  %{
    provider: :openrouter,
    model: "z-ai/glm-5.2:free",
    order: 1,
    priority: 10,
    cost: %{input: 0.0, output: 0.0},
    notes: "OpenRouter free coding/tool route"
  },
  %{
    provider: :openrouter,
    model: "minimax/minimax-m3:free",
    order: 1,
    priority: 20,
    cost: %{input: 0.0, output: 0.0},
    notes: "OpenRouter free coding/tool route"
  },
  %{
    provider: :openrouter,
    model: "thinkingmachines/inkling-small:free",
    order: 1,
    priority: 30,
    cost: %{input: 0.0, output: 0.0},
    notes: "OpenRouter free coding/tool route"
  },
  %{
    provider: :openrouter,
    model: "minimax/minimax-m2.7:free",
    order: 1,
    priority: 40,
    cost: %{input: 0.0, output: 0.0},
    notes: "OpenRouter free coding/tool route"
  },
  %{
    provider: :openrouter,
    model: "thinkingmachines/inkling:free",
    order: 1,
    priority: 50,
    cost: %{input: 0.0, output: 0.0},
    notes: "OpenRouter free coding/tool route"
  },
  %{
    provider: :openrouter,
    model: "nvidia/nemotron-3-ultra-550b-a55b:free",
    order: 1,
    priority: 60,
    cost: %{input: 0.0, output: 0.0},
    notes: "OpenRouter free coding/tool route"
  },
  %{
    provider: :openrouter,
    model: "google/gemma-4-31b-it:free",
    order: 1,
    priority: 70,
    cost: %{input: 0.0, output: 0.0},
    notes: "OpenRouter free coding/tool route"
  },
  %{
    provider: :openrouter,
    model: "google/gemma-4-26b-a4b-it:free",
    order: 1,
    priority: 80,
    cost: %{input: 0.0, output: 0.0},
    notes: "OpenRouter free coding/tool route"
  },
  %{
    provider: :openrouter,
    model: "nvidia/nemotron-3-super-120b-a12b:free",
    order: 1,
    priority: 90,
    cost: %{input: 0.0, output: 0.0},
    notes: "OpenRouter free coding/tool route"
  },
  %{
    provider: :openrouter,
    model: "cohere/north-mini-code:free",
    order: 1,
    priority: 100,
    cost: %{input: 0.0, output: 0.0},
    notes: "OpenRouter free coding/tool route"
  },
  %{
    provider: :openrouter,
    model: "nvidia/nemotron-3.5-lightning:free",
    order: 1,
    priority: 110,
    cost: %{input: 0.0, output: 0.0},
    notes: "OpenRouter free coding/tool route"
  },
  %{
    provider: :openrouter,
    model: "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free",
    order: 1,
    priority: 120,
    cost: %{input: 0.0, output: 0.0},
    notes: "OpenRouter free coding/tool route"
  },
  %{
    provider: :openrouter,
    model: "dots-studio/dots-3-note-preview:free",
    order: 1,
    priority: 130,
    cost: %{input: 0.0, output: 0.0},
    notes: "OpenRouter free preview route; listed expiration 2026-09-30"
  },
  %{
    provider: :openrouter,
    model: "liquid/lfm-2.5-2.6b:free",
    order: 1,
    priority: 140,
    cost: %{input: 0.0, output: 0.0},
    notes: "OpenRouter free tool route; use late for coding because vendor notes limitations"
  },
  %{
    provider: :openrouter,
    model: "poolside/laguna-s-2.1:free",
    order: 1,
    priority: 150,
    cost: %{input: 0.0, output: 0.0},
    notes: "OpenRouter free coding/tool route"
  },
  %{
    provider: :openrouter,
    model: "poolside/laguna-xs-2.1:free",
    order: 1,
    priority: 160,
    cost: %{input: 0.0, output: 0.0},
    notes: "OpenRouter free coding/tool route"
  }
]

config :home, :llm_proxy,
  default_model: {:zai, "glm-5.2"},
  receive_timeout: 180_000,
  model_roles: %{
    "opencode" => "coder",
    "cognee" => "memory"
  },
  model_groups: %{
    "kimi-k3-large" => [
      %{provider: :kimi_coding, model: "k3", order: 1, cost: %{input: 0.0, output: 0.0}},
      %{provider: :openrouter, model: "moonshotai/kimi-k3", order: 2}
    ],
    "kimi-k3-small" => [
      %{provider: :kimi_coding, model: "k3-256k", order: 1, cost: %{input: 0.0, output: 0.0}},
      %{provider: :openrouter, model: "moonshotai/kimi-k3", order: 2}
    ],
    "kimi-k3" => [
      %{provider: :kimi_coding, model: "k3-256k", order: 1, cost: %{input: 0.0, output: 0.0}},
      %{provider: :openrouter, model: "moonshotai/kimi-k3", order: 2}
    ],
    "kimi-k2.7-coding" => [
      %{
        provider: :kimi_coding,
        model: "kimi-for-coding",
        order: 1,
        cost: %{input: 0.0, output: 0.0}
      },
      %{provider: :openrouter, model: "moonshotai/kimi-k2.7-code", order: 2},
      %{provider: :moonshot, model: "kimi-k2.7-code", order: 2}
    ],
    "glm-5.3" => [
      %{provider: :zai, model: "glm-5.3", order: 1, cost: %{input: 0.0, output: 0.0}},
      %{provider: :openrouter, model: "z-ai/glm-5.3", order: 2}
    ],
    "glm-5.2" => [
      %{provider: :zai, model: "glm-5.2", order: 1, cost: %{input: 0.0, output: 0.0}},
      %{provider: :openrouter, model: "z-ai/glm-5.2", order: 2}
    ],
    "background-free" => free_openrouter_coding_routes,
    "free-coding" => free_openrouter_coding_routes,
    "openrouter-free-coding" => free_openrouter_coding_routes
  },
  model_aliases: %{
    "openai/glm-5.2" => [
      {:openrouter, "z-ai/glm-5.2"},
      {:zai, "glm-5.2"},
      {:openrouter, "moonshotai/kimi-k3"}
    ],
    "cognee-chat" => "background-free",
    "openai/background-free" => "background-free",
    "text-embedding-3-small" => [
      {:openrouter, "openai/text-embedding-3-small"},
      {:openai, "text-embedding-3-small"},
      {:ollama, "nomic-embed-text"}
    ],
    "openai/text-embedding-3-small" => [
      {:openrouter, "openai/text-embedding-3-small"},
      {:openai, "text-embedding-3-small"},
      {:ollama, "nomic-embed-text"}
    ]
  }

config :home, :llm_model_prices, %{
  "k3" => %{input: 0.0, output: 0.0},
  "k3-256k" => %{input: 0.0, output: 0.0},
  "kimi-for-coding" => %{input: 0.60, output: 2.50},
  "kimi-for-coding-highspeed" => %{input: 1.80, output: 7.50},
  "kimi-k3" => %{input: 0.60, output: 2.50},
  "moonshotai/kimi-k3" => %{input: 0.60, output: 2.50},
  "moonshotai/kimi-k2.7-code" => %{input: 0.67, output: 3.40},
  "kimi-k2.7-code" => %{input: 0.95, output: 4.00},
  "glm-5.2" => %{input: 0.60, output: 2.20},
  "z-ai/glm-5.2" => %{input: 1.19, output: 3.74},
  "z-ai/glm-5.2:free" => %{input: 0.0, output: 0.0},
  "glm-5.3" => %{input: 0.0, output: 0.0},
  "z-ai/glm-5.3" => %{input: 1.40, output: 4.40},
  "poolside/laguna-s-2.1:free" => %{input: 0.0, output: 0.0},
  "poolside/laguna-xs-2.1:free" => %{input: 0.0, output: 0.0},
  "minimax/minimax-m3:free" => %{input: 0.0, output: 0.0},
  "minimax/minimax-m2.7:free" => %{input: 0.0, output: 0.0},
  "thinkingmachines/inkling:free" => %{input: 0.0, output: 0.0},
  "thinkingmachines/inkling-small:free" => %{input: 0.0, output: 0.0},
  "cohere/north-mini-code:free" => %{input: 0.0, output: 0.0},
  "nvidia/nemotron-3-super-120b-a12b:free" => %{input: 0.0, output: 0.0},
  "nvidia/nemotron-3-ultra-550b-a55b:free" => %{input: 0.0, output: 0.0},
  "nvidia/nemotron-3.5-lightning:free" => %{input: 0.0, output: 0.0},
  "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free" => %{input: 0.0, output: 0.0},
  "google/gemma-4-31b-it:free" => %{input: 0.0, output: 0.0},
  "google/gemma-4-26b-a4b-it:free" => %{input: 0.0, output: 0.0},
  "dots-studio/dots-3-note-preview:free" => %{input: 0.0, output: 0.0},
  "liquid/lfm-2.5-2.6b:free" => %{input: 0.0, output: 0.0},
  "claude-sonnet-4-5" => %{input: 3.00, output: 15.00},
  "claude-opus-4-1" => %{input: 15.00, output: 75.00},
  "claude-haiku-3-5" => %{input: 0.80, output: 4.00},
  "gpt-4.1" => %{input: 2.00, output: 8.00},
  "gpt-4o" => %{input: 2.50, output: 10.00},
  "o4-mini" => %{input: 1.10, output: 4.40},
  "text-embedding-3-small" => %{input: 0.02, output: 0.0}
}

config :home, :llm_projects, %{
  "ops_center" => %{name: "Ops Center", quota_usd: 120.0},
  "mark_mesh" => %{name: "Mark Mesh", quota_usd: 70.0},
  "local_foundation" => %{name: "Local Foundation", quota_usd: 80.0},
  "tools" => %{name: "Tools", quota_usd: 0.0},
  "sandbox" => %{name: "Sandbox", quota_usd: 20.0, enabled: false}
}

config :home, :llm_tools, %{
  "cognee" => %{name: "Cognee", category: "memory"}
}

config :home, :llm_tool_model_attribution, %{
  "cognee-chat" => "cognee",
  "openai/background-free" => "cognee"
}

config :ex_money,
  default_cldr_backend: Agentic.Cldr,
  auto_start_exchange_rate_service: false

# Configure the endpoint
config :home, HomeWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: HomeWeb.ErrorHTML, json: HomeWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Home.PubSub,
  live_view: [signing_salt: "wMZ8yyTp"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :home, Home.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  home: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  home: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
