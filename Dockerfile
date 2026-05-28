# syntax=docker/dockerfile:1
# check=error=true
#
# Carbide2 single-image build: Rails API + EventMachine worker + Vite dev server
# all run from one container via Foreman + Procfile.
#
# Build:
#   docker build -t carbide2 .
# Run via docker compose (preferred) — see docker-compose.yml.

ARG RUBY_VERSION=4.0.0
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

WORKDIR /app

# System packages: postgres client libs, build tools used by gem natives,
# Node.js 20 (Tailwind 4 oxide requires >= 20), and basic runtime utilities.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      curl ca-certificates gnupg git \
      build-essential pkg-config \
      libpq-dev libyaml-dev libjemalloc2 \
      tini && \
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install --no-install-recommends -y nodejs && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

ENV BUNDLE_PATH="/usr/local/bundle" \
    LD_PRELOAD="/usr/local/lib/$(uname -m)-linux-gnu/libjemalloc.so.2"

# --- Bundle install ---
FROM base AS gems
COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

# --- Frontend deps (npm install only; Vite runs in dev mode at runtime) ---
FROM base AS frontend
COPY clients/carbide2-client/package.json clients/carbide2-client/package-lock.json* clients/carbide2-client/
RUN cd clients/carbide2-client && npm install --no-audit --no-fund

# --- Final runtime image ---
FROM base

# Copy gems and node_modules from the build stages
COPY --from=gems "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=frontend /app/clients/carbide2-client/node_modules /app/clients/carbide2-client/node_modules

# Copy application source (server, worker, client, configs)
COPY . .

# Bootsnap precompile for faster boot
RUN bundle exec bootsnap precompile -j 1 --gemfile app/ lib/ || true

# Foreman launches Rails, worker, and Vite together per Procfile.
# Tini is PID 1 for clean signal forwarding.
ENV RAILS_ENV=production \
    PORT=3000 \
    WORKER_PORT=8080 \
    VITE_PORT=5173

EXPOSE 3000 8080 5173

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["bundle", "exec", "foreman", "start", "-f", "Procfile"]
