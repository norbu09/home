# ── Build stage ───────────────────────────────────────────────────────────
ARG ELIXIR_VERSION=1.19-otp-28
ARG DEBIAN_VERSION=trixie-slim

FROM docker.io/library/elixir:${ELIXIR_VERSION} AS builder

ENV MIX_ENV=prod

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

# Copy only what dependency resolution + compilation needs first, so the
# deps layer caches across code changes.
COPY mix.exs mix.lock ./
COPY config/config.exs config/prod.exs ./config/
RUN mix deps.get --only prod && mix deps.compile

# Application source + assets.
COPY priv priv
COPY assets assets
COPY lib lib
COPY rel rel
COPY config/runtime.exs ./config/runtime.exs

RUN mix compile \
    && mix assets.setup \
    && mix assets.deploy \
    && mix release

# ── Runtime stage ─────────────────────────────────────────────────────────
FROM docker.io/library/debian:${DEBIAN_VERSION}

RUN apt-get update -y \
    && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && sed -i '/en_US.UTF-8/s/^# //' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8
ENV MIX_ENV=prod PHX_SERVER=true

WORKDIR /app

COPY --from=builder /app/_build/prod/rel/home ./

RUN chown -R nobody:nogroup /app \
    && mkdir -p /home/agent && chown nobody:nogroup /home/agent
USER nobody

# HOME is where the memory importer looks for agent stores
# (~/.claude, ~/.codex, ~/.local/share/opencode, ~/code) — mount them there.
ENV HOME=/home/agent

EXPOSE 4070

# bin/server runs migrations, then starts the endpoint.
CMD ["bin/server"]
