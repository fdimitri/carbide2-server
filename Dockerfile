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
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg \
      -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
      https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
      > /etc/apt/sources.list.d/docker.list && \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y docker-ce-cli && \
    curl -fsSL -o /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/v1.30.0/bin/linux/$(dpkg --print-architecture)/kubectl" && \
    chmod 0755 /usr/local/bin/kubectl && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

ENV BUNDLE_PATH="/usr/local/bundle"

# --- Bundle install ---
FROM base AS gems
COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

# --- Frontend build: compile Vue SPA into public/ ---
#
# carbide2-server does NOT track a client commit hash (no submodule). The
# meta-repo `carbide2` is the single source of truth for client versions
# and is responsible for invoking docker build with the right context:
#
#   docker build -t carbide2 \
#       --build-context client=../carbide2-client \
#       ./carbide2-server
#
# Requires BuildKit (`docker buildx` or DOCKER_BUILDKIT=1).
FROM node:22-alpine AS dashboard-build
WORKDIR /app
COPY --from=client package.json package-lock.json* ./
RUN npm ci --no-audit --no-fund
COPY --from=client . ./
# VITE_BASE=/ because the Traefik stripprefix middleware removes /w/<id>
# before forwarding to Rails, so the SPA lives at the server root.
ENV VITE_CARBIDE_MODE=workspace VITE_BASE=/
RUN npm run build

# --- Final runtime image ---
FROM base

# Copy gems from the build stage
COPY --from=gems "${BUNDLE_PATH}" "${BUNDLE_PATH}"

# Copy compiled SPA assets into Rails public/ so ActionDispatch::Static
# serves them and SpaController falls back to index.html.
COPY --from=dashboard-build /app/dist /app/public

# Copy application source (server, worker, configs). The client tree is
# already populated above from the frontend stage; we copy the rest of
# the server checkout last so app code changes don't bust the npm cache.
COPY . .

# Bootsnap precompile for faster boot
RUN bundle exec bootsnap precompile -j 1 --gemfile app/ lib/ || true

# Foreman launches Rails, worker, and Vite together per Procfile.
# Tini is PID 1 for clean signal forwarding.
# RAILS_ENV is intentionally NOT set here — docker-compose.yml provides the
# runtime default (currently 'development'). Override via the compose file or
# `docker run -e RAILS_ENV=production` for production deploys.
ENV PORT=3000 \
    WORKER_PORT=8080 \
    VITE_PORT=5173

EXPOSE 3000 8080 5173

ENTRYPOINT ["/usr/bin/tini", "--", "/app/bin/docker-entrypoint"]
CMD ["bundle", "exec", "foreman", "start", "-f", "Procfile"]
