# Bare-metal deployment (no k3d, no Kubernetes, no Traefik)

Status: **design notes / not-yet-automated.** This documents what it takes to run
a CARBIDE workspace directly on a host with **nothing in front** — no reverse
proxy, no ingress controller, no operator. It is written against the current
code so a future non-k3s deployer has a concrete target. Nothing here is wired
into a script yet.

The takeaway up front: **a single-box localhost run is nearly free** because the
app already supports a no-prefix, single-origin mode. The cost of leaving
localhost is almost entirely **TLS**, which is the main job Traefik was doing.

---

## What Traefik/k3d do today (what we're removing)

Per-workspace ingress lives in
[charts/workspace/templates/ingressroute.yaml](charts/workspace/templates/ingressroute.yaml).
Four responsibilities:

1. **Path fan-out under one origin** (one host, one port):
   - `/w/<id>/ws`                      → worker `:8080`
   - `/w/<id>/{api,up,rails,assets}`   → rails `:3000`
   - everything else (`/w/<id>/…`)     → vite `:5173`
2. **`stripPrefix` + `X-Forwarded-Prefix`** — strips `/w/<id>` and tells the SPA
   where it is mounted. Consumed by
   [app/controllers/spa_controller.rb](app/controllers/spa_controller.rb) which
   injects `<base href="/w/<id>/">` into `index.html`.
3. **TLS termination** (self-signed / mkcert) on the `websecure` entrypoint.
4. **HTTP→HTTPS redirect**.

k3d + the control-plane operator (in the `carbide2-control` repo) additionally
provision, per project: a namespace, `Service`, `Deployment`, a CNPG Postgres
database, and the `IngressRoute` above.

A bare-metal deploy replaces all of this with: **serve the SPA from Rails at
root, run the worker on its own port, point one env var at each, terminate TLS
per-process if you leave localhost, and provision the single project by hand.**

---

## Why single-origin/no-prefix already works

None of this needs code changes — the seams already exist:

- **SPA base defaults to `/`.** When `X-Forwarded-Prefix` is absent,
  [spa_controller.rb](app/controllers/spa_controller.rb) sets `base_href = "/"`.
  Serve the built bundle from Rails (`Rails.root/spa/index.html`, already how
  `SpaController#show` works) and SPA + API share origin `:3000` with no prefix.
- **Worker URL is overridable.** The client picks the worker WS URL from, in
  order: `VITE_WORKER_URL` env → `<base href>`+`/ws` → `${host}${base}/ws`
  (see `getWorkerUrl` in the client's `src/services/workerSocket.js`). Setting
  `VITE_WORKER_URL` at build time bypasses the proxy `/ws` path entirely.
- **Worker binds its own host/port.** `WORKER_HOST` (default `0.0.0.0`) /
  `WORKER_PORT` (default `8080`) in
  [worker/worker.rb](worker/worker.rb) — `EM::WebSocket.start(host:, port:)`.
  Auth is a control-plane-minted JWT (`iss: carbide-control`; see
  JWT_CLAIMS.md); the worker does not care what path the WS connects on.
- **Local terminal backend needs no container runtime.** `CARBIDE_BACKEND=local`
  (the default) does a host `PTY.spawn('/bin/bash')` with `cwd = project root`
  — see [worker/handlers/term_handlers.rb](worker/handlers/term_handlers.rb).
  `docker` and `kube` are the other two backends.

---

## The single-box localhost recipe (cheapest path)

Two long-lived processes + a local Postgres. No TLS, no CORS, no proxy —
`http://localhost` is already a browser "secure context" (so even WebRTC
`getUserMedia` works).

1. **Postgres**: a local server; set `DATABASE_URL` (or `POSTGRES_HOST` /
   `POSTGRES_PORT` / `POSTGRES_DB` / credentials — see
   [worker/ar_boot.rb](worker/ar_boot.rb) and `config/database.yml`).
2. **DB setup**: `bundle exec rails db:prepare && bundle exec rails db:seed`.
3. **Build the SPA at root** (`base=/`) and place it where `SpaController` reads
   it (`Rails.root/spa/index.html` + assets). This is the dashboard-build stage
   of the Dockerfile done locally instead of in an image.
4. **Pin the single project** (one pod = one project = one DB is already the
   model):
   - `WORKSPACE_PROJECT_ID=<id>` — enforced in the worker WS handshake
     ([worker/worker.rb](worker/worker.rb)).
   - `FS_PROJECT_ID=<id>` — single-project FS-load override.
5. **Filesystem on disk**: the `local` backend's shell `cwd` is a **disk** path,
   but DBFS is in-database. The worker's startup loader materializes files from
   the project's `root_path` / `FS_ROOT` / `PROJECTS_ROOT/<id>` (default
   `/srv/projects/<id>`) and runs a disk↔DB flusher/inotify watcher. Make sure
   that root exists and is writable so the shell and the editor see the same
   tree. (`docker`/`kube` backends mount a volume; `local` assumes on-disk.)
6. **Run the two processes**:
   - Rails: `bundle exec rails server -b 0.0.0.0 -p 3000`
   - Worker: `WORKER_PORT=8080 CARBIDE_BACKEND=local bundle exec ruby worker/worker.rb`
7. **Point the client at the worker**: build with
   `VITE_WORKER_URL=ws://localhost:8080`.

Browse to `http://localhost:3000/`. The SPA loads from Rails, the API is
same-origin, and the WS goes straight to the worker on `:8080`.

There is **no control plane / dashboard** in this mode — that app
(`carbide2-control`) exists for multi-project provisioning and the `/`
dashboard. A single bare-metal workspace goes straight to the workspace SPA.

---

## Leaving localhost — what it costs

The moment the browser is not on `localhost`, browsers require a secure context
(`https` page + `wss` socket) for WebRTC and secure cookies. With nothing in
front, **each process terminates its own TLS** — this is the real work Traefik
was absorbing.

- **Rails**: `config.force_ssl` / `config.assume_ssl` in
  [config/environments/production.rb](config/environments/production.rb), and
  Puma configured with a cert (`ssl_bind` in `config/puma.rb`) — or run Rails
  behind a tiny local TLS terminator you control.
- **Worker**: `EM::WebSocket.start` accepts `secure: true` +
  `tls_options: { private_key_file:, cert_chain_file: }`. Point it at the same
  cert. Without this the page is `https` and the socket is `ws://` →
  **mixed-content block**. Page and worker must share the scheme.
- **Vite** (only if you run the dev server rather than a static build): `--https`
  with the same cert.
- **One cert, N listeners.** mkcert for LAN, or a real CA cert for a public host.
  There is no wildcard requirement here because we serve at root on a single
  host, not per-workspace subdomains.

CORS is a non-issue when the SPA is served from Rails (same origin) and auth is
token-based (`/api/login` → JWT; no cross-origin session cookie). If you instead
serve the SPA from a separate static/Vite origin, add that origin to
[config/initializers/cors.rb](config/initializers/cors.rb).

---

## Multi-project without an operator

Single-box = one project. To host several projects bare-metal you reimplement
what the control-plane operator does, minus Kubernetes:

- One Postgres database per project (or one DB + strict per-project scoping —
  note the current model assumes **one DB per project**; do not collapse without
  reviewing that assumption).
- One worker + Rails process group per project, each pinned with its own
  `WORKSPACE_PROJECT_ID` / `FS_PROJECT_ID` and its own `WORKER_PORT`.
- A front door that maps project → process group. With no proxy this is either
  distinct ports per project, or you reintroduce a single reverse proxy (nginx/
  Caddy) doing the `stripPrefix` + `X-Forwarded-Prefix` that Traefik did — at
  which point you are back to needing the prefix machinery, which the app
  already supports. **The prefix path is only needed for multi-project on one
  origin; single-project bare-metal skips it entirely.**

This is the piece a future non-k3s deployer would automate. For now, single
project per host is the supported bare-metal shape.

---

## Env var reference (bare-metal relevant)

| Var | Default | Purpose |
|-----|---------|---------|
| `DATABASE_URL` / `POSTGRES_*` | `postgres:5432` | DB connection (Rails + worker share it) |
| `WORKSPACE_PROJECT_ID` | unset | Pin/enforce the single project in the worker handshake |
| `FS_PROJECT_ID` | unset | Single-project FS-load override |
| `FS_ROOT` | — | Disk root for the single project (with `FS_PROJECT_ID`) |
| `PROJECTS_ROOT` | `/srv/projects` | Base dir; per-project is `<root>/<id>` |
| `FS_SKIP_LOAD` | unset | Skip the startup disk→DB load entirely |
| `CARBIDE_BACKEND` | `local` | Terminal backend: `local` \| `docker` \| `kube` |
| `WORKER_HOST` | `0.0.0.0` | Worker WS bind host |
| `WORKER_PORT` | `8080` | Worker WS bind port |
| `CONTROL_JWKS_URL` | — | Public JWKS endpoint for verifying RS256 tokens (ADR-015) |
| `VITE_WORKER_URL` | derived | Build-time client override for the worker WS URL |
