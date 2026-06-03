# Carbide2 IDE Server

A collaborative browser-based development environment. Browser terminals, a Monaco-based editor with real-time co-editing, a virtual filesystem with bidirectional disk sync, IRC-style chat, and an LLM agent with tool-call access to the workspace. Runs on Kubernetes; one pod per workspace, one shell pod per project.

**License:** GPLv3 — see [LICENSE](LICENSE).

---

## Current functional state

What works today (June 2026):

- **Authentication** — Devise email/password. JWT-signed worker tokens per session.
- **Terminals** — PTY shells via the EventMachine worker. Create, destroy, rename, agent-accessible flag. Backend is configurable: local PTY, Docker container, or Kubernetes pod per project (`CARBIDE_BACKEND=local|docker|kube`).
- **Terminal recordings** — asciinema v2 `.cast` files. Start/stop from the UI; REST API for browsing and downloading past sessions.
- **Editor** — Monaco-based file pane with full read/write support. Edits travel as delta operations (`fs/write`) over the worker WebSocket, are stored as `FileChange` revision rows, and broadcast to co-viewers in real time (`applyRemoteChange`). Peer cursor positions are tracked and shown. Binary files show inline image preview or a download link.
- **Virtual filesystem (VFS)** — In-database file store (Postgres `file_changes` revision log). Bidirectional disk sync:
  - `FsLoader` imports a project root into the DB at worker startup.
  - `VfsFlusher` writes dirty DB entries back to disk on a configurable interval (default 800 ms) and on a byte threshold (default 20 bytes). Settings tunable per-project via the API.
  - `VfsWatcher` watches disk via inotify and pushes external changes (e.g. edits in a terminal) into the DB, then broadcasts `fs/set_contents` so open editors update immediately.
  - Binary files tracked (stat/mtime only, content on disk). POSIX mode/owner metadata stored.
  - Archive import: upload `.tar.gz` or `.zip` via the UI to populate a project.
- **Chat** — IRC-style channels (join/leave, persistent message history, typing indicators). Channels also host **WebRTC video calls** — a call shares the same context as the text channel. Full-mesh peer-to-peer (newcomer offers, glare-free); the worker is a pure signalling relay (`rtc/join`, `rtc/leave`, `rtc/signal`) and never inspects SDP/ICE. Mic/camera toggles in the chat header. Public STUN only for now — no TURN, so calls between peers behind symmetric NAT may fail until a TURN server is configured.
- **LLM agent** — Rudimentary but working. Worker-side agent sessions run a tool-call loop against a single hardcoded OpenAI-compatible HTTP endpoint. Per-project conversation history with project/private visibility. Tool results streamed to the client. Conversation list and replay.
- **Project settings** — Per-project: VFS root path, flush interval, flush byte threshold, shell image override.
- **Debug stream** — Structured worker log event bus; subscribable from the client debug pane.
- **Landing page** — Styled splash at `/` with CARBIDE acronym easter egg. `/about` redirects to the SPA About page; `GET /about?format=json` returns acronym data for the SPA.

**Known gaps:**

- Flusher/watcher not started for projects created after worker boot — worker restart needed (see Backlog #4).
- Client IP not propagated to Rails logs — Traefik `externalTrafficPolicy` and `trusted_proxies` not wired up.
- LSP not connected — Monaco is installed and language-aware, but no language server proxy yet.

---

## Architecture

```
Browser
  │  HTTP/WS
  ▼
Traefik (IngressRoute)
  ├─ /w/<id>/ws  ──────────────────► Worker (EventMachine, port 8080)
  ├─ /w/<id>/api, /assets, /up ───► Rails API (Puma, port 3000)
  └─ /w/<id>/    (everything else)► Vite dev server (port 5173)
  └─ /, /about, /landing.css ─────► Rails (LandingController)

Workspace pod (k8s Deployment ws-<id> in namespace ws-<id>):
  Foreman runs: rails | worker | vite

Worker:
  ├── term handlers  → PTY (local | docker exec | kubectl exec into project shell pod)
  ├── fs handlers    → FsStore (FileChange revisions) + VfsFlusher + VfsWatcher (inotify)
  ├── chat handlers  → ChatRoom broadcast
  ├── agent handlers → AgentSession → OpenAI-compatible HTTP API
  └── debug handlers → DebugStream pub/sub

Database: CloudNativePG (Postgres) — shared cluster, one DB per workspace.
Storage:  PersistentVolumeClaim per workspace, mounted at /srv/projects/<projectId>/.
```

Three processes share a single pod:

- **Rails** (`app/`) — REST API (API-only mode) + `LandingController` (uses `ActionController::Base`). Handles Devise auth, VFS CRUD (`/api/projects/:id/fs/...`), recordings index/download, project settings, chat history.
- **Worker** (`worker/`) — EventMachine WebSocket server. Handles all real-time traffic: terminals, file edits, chat, agent tool calls, debug stream. Boots AR directly (`worker/ar_boot.rb`) — no Rails stack, no autoloader, no `Rails.root`.
- **Vite** — serves the Vue 3 SPA in development. In production this would be a separate build+nginx container (see Backlog #6).

**VFS write path (editor → disk):**

```
Monaco keypress
  → FilePane.onEditorChange (delta array)
  → workerSocket fs/write
  → FsStore.handle_write → FileChange.append! (DB)
  → broadcast fs/change to co-viewers → applyRemoteChange in peer Monacos
  → VfsFlusher.record_write → flush_single → File.write (disk)
```

**VFS inotify path (disk → editor):**

```
External write (terminal, git checkout, etc.)
  → inotify close_write event
  → VfsWatcher.handle_event → FileChange.append! setContents (DB)
  → broadcast fs/set_contents → FilePane.onFsSetContents → editor.setValue
```

For Vue/Vite client internals, see the [carbide2-client](https://github.com/fdimitri/carbide2-client) repo (`ARCHITECTURE.md`).

---

## Development setup

**Primary path: k3d (Kubernetes-in-Docker).** This is the tested path.

```bash
git clone --recurse-submodules https://github.com/fdimitri/carbide2-server.git
cd carbide2-server

# Bring up k3d cluster + Traefik + CNPG + Postgres (~5 min first time)
./scripts/dev-cluster.sh

# Build and import the workspace image
docker build -t carbide2:dev .
k3d image import carbide2:dev -c carbide-dev

# Install workspace 1
helm upgrade --install ws-1 charts/workspace \
  -n ws-1 --create-namespace --set projectId=1
kubectl -n ws-1 rollout status deploy/ws-1 --timeout=5m

# Open the app
open http://localhost:8080/
```

Default login: `dev@example.com` / `password`

See [DEPLOY-k3d.md](DEPLOY-k3d.md) for the full step-by-step (host packages, kubectl, Helm, k3d install) and [KUBE.md](KUBE.md) for cluster inspection commands.

**Iterating on code:**

```bash
# Full image rebuild + redeploy (~60 s)
docker build -t carbide2:dev . \
  && k3d image import carbide2:dev -c carbide-dev \
  && kubectl -n ws-1 rollout restart deploy/ws-1

# Overlay a single file without full rebuild (faster)
printf 'FROM carbide2:dev\nCOPY worker/vfs_flusher.rb /app/worker/vfs_flusher.rb\n' \
  | docker build -f - -t carbide2:dev . \
  && k3d image import carbide2:dev -c carbide-dev \
  && kubectl -n ws-1 rollout restart deploy/ws-1

# Vue/Vite changes pick up via HMR — no restart needed
```

**Alternative: Docker Compose** (no k8s):

```bash
./quickstart.sh --rebuild
```

See [INSTALL.md](INSTALL.md) for the Compose walkthrough. Note: Compose and k3d both bind ports 3000/5173/8080 — don't run both. `quickstart.sh` refuses to start if a `carbide-*` k3d cluster exists.

---

## Key environment variables

| Variable | Default | Purpose |
|---|---|---|
| `WORKER_JWT_SECRET` | `replace_me` | Signs worker WebSocket tokens — **must change in production** |
| `RAILS_MASTER_KEY` | (from `config/master.key`) | Decrypts `config/credentials.yml.enc` — deliver via k8s Secret or env var, never commit |
| `CARBIDE_BACKEND` | `local` | Terminal backend: `local`, `docker`, or `kube` |
| `CARBIDE_SHELL_IMAGE` | `carbide2-shell:dev` | Image for per-project shell containers/pods |
| `CARBIDE_NAMESPACE` | (from service account) | k8s namespace for shell pods (`kube` backend) |
| `PROJECTS_ROOT` | `/srv/projects` | Server-side root for project files |
| `CARBIDE_FLUSH_INTERVAL` | `0.8` | VFS flush period in seconds |
| `CARBIDE_FLUSH_BYTES` | `20` | VFS flush byte threshold |
| `FS_SKIP_LOAD` | unset | Set to `1` to skip VFS load on worker startup |

---

## Running tests

```bash
# All layers: bash smoke → helm test → rails test → playwright
./scripts/test-substrate.sh

# Individual layers
./scripts/smoke-test.sh ws-1                          # HTTP probe
helm test ws-1 -n ws-1                                # chart smoke pod
./scripts/test-rails.sh ws-1                          # rails test inside pod
cd ${CARBIDE2_CLIENT:-../carbide2-client} && npm run test:smoke       # Playwright smoke
```

CI runs `.github/workflows/substrate-tests.yml`.

---

## Repository layout

```
app/              Rails controllers, models, services, views (landing only)
worker/           EventMachine worker — terminals, VFS, chat, agent
  handlers/       TermHandlers, FsHandlers, ChatHandlers, AgentHandlers
clients/
  carbide2-client/  Vue 3 + Vite SPA (git submodule → github.com/fdimitri/carbide2-client)
charts/workspace/ Helm chart for per-workspace k8s deployment
config/           Rails config, routes, credentials
db/               Migrations, seeds, schema
deploy/           CNPG cluster manifest
scripts/          dev-cluster.sh, test-substrate.sh, import-host-dir.sh, etc.
```

---

## Backlog

Rough priority order. Two guiding principles:

- **Substrate-amplifiers first.** Things that use the collab editor + agent + VFS (`propose_patch`, CRDT, LSP, gists, diagrams) compound on what already makes this project different. Standalone commodity features (ticketing, kanban) sit lower.
- **Integration > best-in-class for in-room tools.** We won't beat Slack at chat or Zoom at video, but having them *inside* the workspace — same auth, same project context, same window — is the point. Don't skip them just because incumbents exist.

Quality bar before any item ships: keyboard-operable, p95 interaction <100 ms on the dev cluster, and a named-incumbent gut check ("would I open this instead of GitHub Issues / Linear / Excalidraw / Discord?"). If the answer is no, it stays in the backlog regardless of how much code is written.

1. **Project import from git URL** — on project create, accept an optional `git_url` (+ branch, + optional token). Worker clones into the VFS root path, then `FsLoader` imports as usual. Natural pair with the existing tar/zip import. First version HTTPS-only with token-in-secret; SSH key management can wait.
2. **Agent: `propose_patch` tool** — writes a staged `FileChange` revision instead of overwriting, so multi-user collab stays consistent and the user accepts/rejects in the editor. First agent "killer tool".
3. **WebRTC voice/video/screen** — must-have, even though incumbents are better in isolation. Integration is the value: same auth, same room, same window. Peer-to-peer mesh for ≤4 peers. Worker as signaling server only (`rtc/offer`, `rtc/answer`, `rtc/ice` over the existing WS); public STUN + optional TURN env var. Screen-share track piggybacks on the same `RTCPeerConnection`. Dockable pane; mute/camera toggles in chat header. SFU deferred until peer count justifies it.
4. **Markdown preview pane** — split-view toggle for `.md` files using the existing `utils/markdown.js`. Live re-render on `fs/change`. Same renderer as chat messages so style stays consistent.
5. **Gists** — durable, revisioned snippet store (not paste-and-forget). A gist is a project with `kind: 'gist'`, reusing `DirectoryEntry` + `FileChange`. Single- or multi-file, fork, comment, public-by-token URL. Embed in chat as a `gist://` reference rendering inline as a read-only Monaco. More useful than a pastebin because edits stay versioned.
6. **Activity feed** — safe to build because it's data-out: there's no UX surface to ruin. Per-project event stream merging chat, `FileChange` revisions, terminal sessions, agent actions, issue events. Emit as **ActivityStreams 2.0** JSON (W3C, the modern successor to Atom/RSS, substrate of the Fediverse) at `/api/projects/:id/activity.json`. Optional Atom view at `.atom` for feed readers — cheap to add on top of AS2. Worker pushes new entries over WS (`activity/new`) for live UI updates.
7. **Diagram pane (UML, flowcharts, sequence, ERD)** — text-first diagrams stored as `.mmd` / `.puml` / `.d2` files in the VFS so they version, diff, and merge like code. Split-view Monaco + live preview: Mermaid (sequence, flow, class, state, ER, gantt) covers ~80%, PlantUML for heavier UML via sidecar `plantuml.jar`, optional D2 for prettier layouts. Click-to-insert into chat/issues/markdown via the existing markdown renderer's fenced-block hook.
8. **CRDT / real-time co-editing** — Yjs Y.Doc per open file held in the worker, persisted to DB. The `FileChange` revision log is the natural snapshot substrate; decision needed on whether revisions snapshot from the CRDT or the CRDT layers on top of revisions. The current delta-broadcast path works for two-user sessions but is fragile under reordering/disconnect.
9. **LSP multiplexing** — one LSP process per (project, language) in the shell pod; worker proxies LSP messages over WS. `clangd`, `rust-analyzer`, `gopls`, `pyright`, `typescript-language-server` as the first set. Monaco is already language-aware.
10. **Agent: model/endpoint orchestration** — endpoint is currently hardcoded in the worker. Need a registry of available models and endpoints (per-workspace or per-user), per-agent model selection, and runtime swap without restarting the worker.
11. **Generic task/command registry** — declarative `.carbide/tasks.yml` per project. Think VS Code `tasks.json` or `Makefile` targets surfaced as UI buttons: user declares named commands (`build`, `test`, `lint`, `flash-firmware`...); each renders as a clickable button in a Tasks pane; worker runs the command in the shell pod and streams output. Replaces the alternative of writing bespoke Vue + worker glue for every toolchain (a "PlatformIO panel", an "npm scripts panel", a "cargo panel"). Adding a new build system becomes a YAML edit by the user, not a code change by us. Bonus: the agent's `shell_exec` tool can call registered tasks by name, so "run the build" stays declarative instead of letting the LLM invent shell strings.
12. **Lazy-start flusher/watcher** — `VFS_FLUSHERS`/`VFS_WATCHERS` are populated once at boot from `Project.pluck(:id)`. Projects created after worker boot need a worker restart to get disk sync. Fix: lazy-start when a WS session connects for an unknown `project_id`.
13. **Client IP in Rails logs** — `externalTrafficPolicy: Local` on Traefik service + `action_dispatch.trusted_proxies` in Rails. Currently logs show kube-proxy gateway IP.
14. **Frontend container split** — `Dockerfile.frontend` builds `dist/` via nginx; new `frontend` Deployment+Service in `charts/workspace`. Same origin, no CORS changes needed. Shrinks server image and decouples rebuild cycles.
15. **Production deploy hardening** — `RAILS_MASTER_KEY` k8s Secret mount in chart; `assume_ssl`/`force_ssl`; real ingress hostname; documented production Helm values file.
16. **Integrated ticketing** — *commodity feature; do only if we can clear the quality bar.* Per-project issue tracker (à la GitHub Issues). Models: `Issue`, `IssueComment`. Reuse chat markdown rendering and `FileChange` cross-linking (`#42` in commit messages auto-closes). Tight scope: list/detail/create/comment/close — no board fields, no SLAs.
17. **Kanban board** — *commodity feature, depends on #16.* Column view on top of issues. `BoardColumn` rows per project; `Issue.column_id`. Drag-reorder via WS. Avoid the "shitty knockoff" trap by deferring swimlanes, WIP limits, and custom fields to a follow-up — or skip entirely if users prefer Linear.

---

## Contributing

GPG-signed commits are required. Never disable signing (`git -c commit.gpgsign=false` is prohibited). Do not amend or force-push already-pushed commits.

Update the **Backlog** section above together with the code — keep functional state accurate on every feature commit.
