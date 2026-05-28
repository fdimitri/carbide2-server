# Carbide2 Server — Installation Guide

The supported deployment is **Docker Compose**. A native install is still
possible but no longer tested; see "Native install" at the bottom.

## System Requirements

| Component       | Version                                                |
|-----------------|--------------------------------------------------------|
| Docker Engine   | 25.0+ (named-volume `subpath` mounts)                  |
| Docker Compose  | v2 (the `docker compose` plugin)                       |
| OS              | Linux (inotify required for FS watching)               |
| Disk            | ~6 GB free (carbide image ~1.5 GB, shell image ~4 GB)  |

That's it on the host side — Ruby, Node, Postgres, etc. all live inside the
containers.

---

## TL;DR

```bash
git clone --recurse-submodules https://github.com/fdimitri/carbide2-server.git
cd carbide2-server
./quickstart.sh --rebuild           # add --shell to also build the terminal image (~4GB, slow)
```

The script does preflight checks, generates a sane `.env`, brings up the
stack, waits for `/up`, and prints the URLs and dev credentials. The numbered
steps below are what `quickstart.sh` does, broken out for the curious or for
production deploys.

---

## 1. Clone the repository

The Vue client lives in a submodule (`clients/carbide2-client`), so use
`--recurse-submodules` or pull them after the fact:

```bash
git clone --recurse-submodules https://github.com/fdimitri/carbide2-server.git
cd carbide2-server

# Or, if you already cloned without it:
git submodule update --init --recursive
```

---

## 2. (Optional) Configure environment

A `.env` file at the repo root is auto-loaded by Compose. The defaults work
out-of-the-box for local development; override these for non-local deploys:

```dotenv
# Strong password if you expose Postgres beyond localhost
POSTGRES_PASSWORD=carbide

# JWT secret used to sign worker tokens (MUST be set in production)
WORKER_JWT_SECRET=changeme-please

# CORS origins (comma-separated list of literal origins or /regex/ patterns).
# Leave unset for the dev default (localhost / 127.0.0.1 / 192.168.x.x).
CARBIDE_CORS_ORIGINS=

# Run as RAILS_ENV=production (defaults to development)
# RAILS_ENV=production
```

`.env` is gitignored.

---

## 3. Build and start the stack

```bash
docker compose up --build -d
```

This builds two images and starts two containers:

| Service     | Image                  | Ports                          |
|-------------|------------------------|--------------------------------|
| `postgres`  | `postgres:16`          | 5432 (internal only)           |
| `carbide`   | `carbide2-server`      | 3000 (Rails), 8080 (worker WS), 5173 (Vite dev) |

The `carbide` image runs three processes under Foreman:
Rails API + worker (PTY/FS/chat) + Vite dev server.

Database migrations run automatically on container start via
`bin/docker-entrypoint`.

Also build the **shell image** used to spawn per-project terminals:

```bash
docker build -f Dockerfile.shell -t carbide2-shell .
```

This is a separate ~4 GB image with build tools, embedded toolchains
(arm-none-eabi-gcc for STM32, avr-gcc for Arduino/AVR, esptool + PlatformIO
for ESP), Rust, Python, Ruby, Node, Go, and net diagnostics.

---

## 4. Verify the install

Health check:

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3000/up   # → 200
```

Browser: open <http://localhost:5173>, log in with the seeded dev account:

| Field    | Value             |
|----------|-------------------|
| Email    | `dev@example.com` |
| Password | `password`        |

You should land on the dashboard showing the seeded **Demo Project**.

---

## 5. Import a project into the workspace

New projects start empty but already have their `root_path` wired to
`/srv/projects/<id>/` inside the shared volume (set automatically by
`Project#ensure_project_setting!` on create). Three ways to populate one:

**a) From a host directory** (one-shot copy via the helper script):

```bash
./scripts/import-host-dir.sh /path/to/your/code 1
```

This rsyncs into the `carbide-projects` volume at `/srv/projects/1/`,
excluding `.git`, `node_modules`, `tmp`, `log`, `vendor/bundle`, then
restarts the worker so `FsLoader` re-ingests.

**b) From the carbide UI**: open a terminal and `git clone` directly into
`/workspace`. New files are picked up by the inotify watcher.

**c) Manually**: write to `/srv/projects/<id>/` inside the `carbide-projects`
volume via any container that mounts it, then `docker compose restart carbide`.

---

## Storage layout

All persistent data lives in two named Docker volumes:

| Volume             | Mount point          | Contents                          |
|--------------------|----------------------|-----------------------------------|
| `carbide-postgres` | (inside postgres)    | Postgres datadir                  |
| `carbide-projects` | `/srv/projects`      | Per-project workspaces (`/<id>/`) |

Backup/restore the project volume with the included helper:

```bash
./scripts/migrate-storage.sh export ~/carbide-projects.tar.gz
./scripts/migrate-storage.sh import ~/carbide-projects.tar.gz
```

---

## Common operations

```bash
# View live logs (all services)
docker compose logs -f

# Rails console
docker compose exec carbide bundle exec rails console

# psql against the dev database
docker compose exec postgres psql -U carbide -d carbide2_development

# Rebuild after changing Dockerfile / Gemfile / package.json
docker compose up --build -d

# Stop everything (volumes preserved)
docker compose down

# Stop AND delete all data (irreversible)
docker compose down -v
```

If your user isn't in the `docker` group, prefix the above with
`sg docker -c '...'` or add yourself:

```bash
sudo usermod -aG docker $USER
newgrp docker
```

---

## Running tests

```bash
# Rails unit/model tests (inside the carbide container)
docker compose exec carbide bundle exec rails test

# Playwright e2e (against the running stack, run on the host)
cd clients/carbide2-client
npx playwright install --with-deps   # one-time
npx playwright test --reporter=list
```

Some `chat.spec.js` selectors are stale (the dock got refactored) and will
fail until updated; the WS path and FS path are still covered by the smoke
and editor specs.

---

## Troubleshooting

**`permission denied while trying to connect to the Docker daemon socket`**
You're not in the `docker` group. `sudo usermod -aG docker $USER && newgrp docker`.

**`docker compose: unknown command`**
You're on Compose v1 (legacy `docker-compose`). Install v2:
`sudo apt install docker-compose-plugin`. The `docker-compose.yml` is
compatible with both.

**Rails error: `Database "carbide2_development" does not exist`**
The entrypoint runs `db:prepare` on startup, but something killed the previous
attempt. Try `docker compose restart carbide` and check
`docker compose logs carbide`. If `POSTGRES_DB` is set in `.env` or shell env,
unset it — `config/database.yml` picks the env-suffixed name.

**Project file tree is empty in the UI**
The project's workspace directory (`/srv/projects/<id>/`) is empty. Import
something into it — see step 5.

**Terminal creation: `No such file or directory - docker`**
The `carbide` image was built without the Docker CLI. Rebuild:
`docker compose build --no-cache carbide`.

**Worker logs flood with VfsFlusher entries**
Expected during the initial FS load (every file gets persisted to the DB).
The current loader has no exclude list — `node_modules` and `.git` get
ingested. Skip large project trees or accept the one-time ingestion cost.

---

## Native install (legacy, untested)

The pre-Docker install path (`./dev.sh` with Ruby/Node/SQLite on the host) is
preserved in the git history but is no longer the supported configuration and
has not been tested against the current Postgres-only `database.yml`. Use it
at your own risk; the Docker path above is the source of truth.

