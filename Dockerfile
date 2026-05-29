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
# RAILS_ENV is intentionally NOT set here — docker-compose.yml provides the
# runtime default (currently 'development'). Override via the compose file or
# `docker run -e RAILS_ENV=production` for production deploys.
ENV PORT=3000 \
    WORKER_PORT=8080 \
    VITE_PORT=5173

EXPOSE 3000 8080 5173

ENTRYPOINT ["/usr/bin/tini", "--", "/app/bin/docker-entrypoint"]
CMD ["bundle", "exec", "foreman", "start", "-f", "Procfile"]
