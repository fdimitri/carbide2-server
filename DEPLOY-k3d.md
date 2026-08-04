# DEPLOY-k3d.md — superseded

> **The fresh-machine k3d setup this file used to describe is obsolete.**
> The k3d deploy path is now owned by the meta-repo
> ([fdimitri/carbide2](https://github.com/fdimitri/carbide2)) and is fully
> automated. The manual `apt install` / `helm install` / `k3d image import`
> steps are done for you by `scripts/setmeup.sh` (host provisioning) and
> `scripts/deploy.rb` (build → cluster → import → CRD → control plane).

## Fresh-host deploy (current)

Run these from the **meta-repo**, not this one:

```sh
# 1. Provision host tools (Ubuntu 24.04). Then log out/in for the docker group.
./scripts/setmeup.sh                 # add --all for Node + socat + mkcert

# 2. Clone the meta-repo with submodules (if you haven't already)
git clone --recurse-submodules https://github.com/fdimitri/carbide2.git
cd carbide2

# 3. One idempotent command: build → cluster/infra → import → CRD → control plane
./scripts/deploy.rb
```

See the meta-repo [README](https://github.com/fdimitri/carbide2#readme) for the
prerequisites table, pinned tool versions, and `deploy.rb` flags. For the
alternative single-host **docker-compose** stack (not k3d), see
[INSTALL.md](INSTALL.md) / [quickstart.sh](quickstart.sh) in this repo.

## Day-to-day cluster shortcuts (still current)

```sh
k3d cluster stop  carbide-dev      # pause (state preserved on disk)
k3d cluster start carbide-dev      # resume
k3d cluster delete carbide-dev     # nuke everything cluster-side
```

Run the substrate test layers (bash smoke → `helm test` → in-pod Rails
minitest → Playwright):

```sh
./scripts/test-substrate.sh
```

See [KUBE.md](KUBE.md) for an orientation to what the cluster is made of and how
to inspect it.

