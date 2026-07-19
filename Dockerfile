# syntax=docker/dockerfile:1
# check=error=true
#
# Carbide2 single-image build: Rails API + EventMachine worker run from one
# container via Foreman + Procfile.
#
# The SPA client is NOT baked into this image. Clients live only in the MinIO
# static tier (built + uploaded by the meta-repo scripts/build-client and
# deploy.rb), served at /clients/<family>/<sha>/. The Rails SpaController is a
# loader that resolves + serves the pinned client's index.html at request time.
#
# Build:
#   docker build -t carbide2 .
# Run via docker compose (preferred) — see docker-compose.yml.

ARG RUBY_VERSION=4.0.0
ARG META_SHA=unknown
ARG CLIENT_SHA=unknown
ARG SERVER_SHA=unknown
ARG WORKER_SHA=unknown
ARG BUILD_TIME=unknown
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

# --- Final runtime image ---
FROM base

# Copy gems from the build stage
COPY --from=gems "${BUNDLE_PATH}" "${BUNDLE_PATH}"

# Copy application source (server, configs). We copy the server checkout last so
# app code changes don't bust the earlier layers. No SPA client is copied in —
# it is served from the MinIO static tier, not from this image.
COPY . .

# Worker comes from its own repo (carbide2-worker). In the server checkout
# 'worker' is a symlink to ../carbide2-worker for local dev convenience;
# Docker won't follow symlinks outside the build context, so we copy it
# explicitly here from a named build context and overwrite the symlink.
#   docker buildx build --build-context worker=../carbide2-worker ...
RUN rm -rf /app/worker
COPY --from=worker . /app/worker/

# Bootsnap precompile for faster boot
RUN bundle exec bootsnap precompile -j 1 --gemfile app/ lib/ || true

# Foreman launches Rails and the worker together per Procfile.
# Tini is PID 1 for clean signal forwarding.
# RAILS_ENV is intentionally NOT set here — docker-compose.yml provides the
# runtime default (currently 'development'). Override via the compose file or
# `docker run -e RAILS_ENV=production` for production deploys.
ENV PORT=3000 \
    WORKER_PORT=8080

EXPOSE 3000 8080

ENTRYPOINT ["/usr/bin/tini", "--", "/app/bin/docker-entrypoint"]
CMD ["bundle", "exec", "foreman", "start", "-f", "Procfile"]
