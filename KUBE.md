# KUBE.md — Quick orientation for inspecting the carbide2 dev cluster

You don't need to know Kubernetes to operate this — most of it is automation.
What follows is the minimum mental model plus the commands you can paste to
see what's going on.

## Mental model in 60 seconds

- **Cluster** = a Kubernetes control plane + worker nodes. Ours runs locally
  inside Docker via **k3d** (k3s-in-Docker). Cluster name: `carbide-dev`.
- **Node** = a machine (or container) that runs your workloads. We have one.
- **Namespace** = a folder for resources. Ours of interest:
  - `kube-system`, `traefik`, `cnpg-system` — infrastructure.
  - `carbide-system` — the shared Postgres (CloudNativePG, "CNPG") cluster.
  - `ws-1`, `ws-2`, ... — one per workspace/project.
- **Pod** = the running container(s). One `ws-1` pod runs the Rails server.
- **Deployment** = a controller that keeps N pods alive and rolls updates.
- **Service** = a stable cluster-internal DNS name + IP for a set of pods.
  e.g. `ws-1.ws-1.svc.cluster.local:3000` reaches the workspace Rails app.
- **IngressRoute** (Traefik CRD) = "route external HTTP `/w/1/*` to the
  `ws-1` service". This is how the browser reaches the workspace.
- **PVC** (PersistentVolumeClaim) = a disk attached to a pod. Each workspace
  has one for `/srv/projects/<projectId>`.
- **Helm chart** = a templated bundle of K8s manifests + a values file. Our
  per-workspace chart is `charts/workspace`; each install of it is a
  **release** (e.g. `ws-1`).
- **CRD** = a custom resource type registered by an operator. Traefik adds
  `IngressRoute`; CNPG adds `Cluster` and `Database`.

## Layout in this repo

| Path                                           | What it is                                    |
| ---------------------------------------------- | --------------------------------------------- |
| `scripts/dev-cluster.sh`                       | Brings up k3d + Traefik + CNPG + Postgres.    |
| `deploy/cnpg-cluster.yaml`                     | The shared `carbide-pg` Postgres definition.  |
| `charts/workspace/`                            | Per-workspace Helm chart (deploy + svc + ingress + PVC + test pod). |
| `scripts/smoke-test.sh`                        | HTTP probe of `/up` via Traefik.              |
| `scripts/test-rails.sh`                        | `rails test` inside the workspace pod.        |
| `scripts/test-substrate.sh`                    | Runs all 4 test layers in order.              |
| `.github/workflows/substrate-tests.yml`        | CI: builds everything from scratch and runs the orchestrator. |

## The "show me everything" commands

Most useful inspection commands, roughly in the order you'd reach for them:

```sh
# Where am I pointing? Which cluster does kubectl talk to?
kubectl config current-context        # should be: k3d-carbide-dev

# All pods everywhere, with status and restart counts.
kubectl get pods -A

# A specific namespace.
kubectl -n ws-1 get all
kubectl -n carbide-system get cluster,pods   # CNPG status

# Why is X unhappy? "describe" shows events at the bottom.
kubectl -n ws-1 describe pod ws-1-<hash>

# Logs (the workspace Rails server log).
kubectl -n ws-1 logs deploy/ws-1                    # current container
kubectl -n ws-1 logs deploy/ws-1 -c workspace --tail=200
kubectl -n ws-1 logs deploy/ws-1 -p                 # previous (crashed) container
kubectl -n ws-1 logs -f deploy/ws-1                 # follow / tail -f

# Open a shell inside the workspace pod.
kubectl -n ws-1 exec -it deploy/ws-1 -c workspace -- bash

# Quick one-shot command in the pod.
kubectl -n ws-1 exec deploy/ws-1 -c workspace -- bundle exec rails runner 'puts Project.count'

# What services and ingress routes exist?
kubectl -n ws-1 get svc
kubectl -n ws-1 get ingressroute

# Disk usage (PVCs).
kubectl get pvc -A
```

## Helm — installed apps

```sh
helm list -A                                      # all installed releases
helm -n ws-1 status ws-1                          # current state of one release
helm -n ws-1 get values ws-1                      # the values it was installed with
helm -n ws-1 get manifest ws-1 | less             # rendered YAML actually applied
helm -n ws-1 upgrade ws-1 charts/workspace --reuse-values
helm test ws-1 -n ws-1                            # run the chart's smoke pod
helm -n ws-1 uninstall ws-1                       # remove the release entirely
```

## Talking to the workspace from outside the cluster

Traefik listens on host port `8080` (and `8443`). The workspace ingress
strips the `/w/<projectId>` prefix and forwards to the pod's port 3000.

```sh
curl -i http://localhost:8080/w/1/up              # Rails health endpoint
curl    http://localhost:8080/w/1/                # the app itself
```

If you ever get a `403` with a "Blocked host" page, that's Rails 8's
`config.hosts` allowlist refusing the request — not Traefik. Either go
through `localhost`/Traefik, or add the host to `config.hosts` for that env.

## Talking to Postgres directly

CNPG manages a primary pod called `carbide-pg-1`. Credentials live in a
secret named `carbide-pg-app`.

```sh
# Open psql inside the primary pod (uses the app role automatically):
kubectl -n carbide-system exec -it carbide-pg-1 -- psql

# List databases / sizes:
kubectl -n carbide-system exec -it carbide-pg-1 -- psql -c '\l+'

# CNPG status (replication, switchover, backups):
kubectl -n carbide-system get cluster carbide-pg -o yaml | less
```

Note: in dev we grant the `carbide` role `CREATEDB` + `SUPERUSER` via
`deploy/cnpg-cluster.yaml` so Rails can run `db:create`/`db:drop` for the
test database. **Do not** copy that into production.

## When something is "stuck"

- Pod status `Pending` → look at `kubectl describe`; usually a PVC has no
  storage class or there's a scheduling constraint nothing satisfies.
- Pod status `CrashLoopBackOff` → `kubectl logs ... -p` to see the previous
  crash output.
- Pod status `ImagePullBackOff` → the image isn't on the node. For k3d:
  `k3d image import carbide2:dev -c carbide-dev`.
- Helm release stuck `pending-upgrade` → `helm history` then
  `helm rollback`.

## Tearing it all down

```sh
k3d cluster stop  carbide-dev   # keeps state on disk
k3d cluster start carbide-dev
k3d cluster delete carbide-dev  # wipes everything in the cluster
```

The Docker image (`carbide2:dev`) and the cloned repo are unaffected by any
of these.
