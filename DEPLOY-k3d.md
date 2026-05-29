# DEPLOY-k3d.md — Fresh-machine setup for the carbide2 dev cluster

> Temporary doc. This is the **development** path that uses k3d (k3s in
> Docker) on a single machine — *not* the production install. Once we
> have a real production target, move the persistent parts of this into
> `INSTALL.md` and delete this file.

Target: Linux x86_64 (Debian/Ubuntu or WSL2 Ubuntu). Other distros work
but you'll need to translate the package commands.

## 1. Host packages

```sh
sudo apt update
sudo apt install -y \
  build-essential git curl ca-certificates gnupg lsb-release \
  pkg-config libpq-dev libyaml-dev libffi-dev zlib1g-dev libssl-dev \
  libreadline-dev libsqlite3-dev autoconf bison \
  postgresql-client
```

`libpq-dev` is required by the `pg` gem; `postgresql-client` gives you
`psql` for poking at the CNPG database.

## 2. Docker

k3d runs Kubernetes nodes as Docker containers, so you need a working
Docker daemon that your user can talk to without sudo.

```sh
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"
# log out and back in (or: newgrp docker) so the group takes effect
docker run --rm hello-world      # sanity check
```

On WSL2: install Docker Desktop on Windows and enable WSL integration
for your distro, or run dockerd directly inside WSL.

## 3. kubectl

```sh
curl -fsSLo /tmp/kubectl https://dl.k8s.io/release/v1.30.0/bin/linux/amd64/kubectl
sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
kubectl version --client
```

## 4. Helm

```sh
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

## 5. k3d

```sh
curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | TAG=v5.7.4 bash
k3d version
```

## 6. Ruby (for running tests / console outside the cluster)

Pick one. `rbenv` is the lightest option:

```sh
git clone https://github.com/rbenv/rbenv.git ~/.rbenv
git clone https://github.com/rbenv/ruby-build.git ~/.rbenv/plugins/ruby-build
echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> ~/.bashrc
echo 'eval "$(rbenv init - bash)"' >> ~/.bashrc
exec "$SHELL" -l

rbenv install 3.4.5      # match .ruby-version when it lands
rbenv global  3.4.5
gem install bundler
```

> The README targets Ruby 4.0 / Rails 8.1; until 4.0 ships you can run
> the in-pod tests, which use whatever Ruby is baked into the image and
> don't depend on the host Ruby at all.

## 7. Node.js (for the Vite client + Playwright)

```sh
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo bash -
sudo apt install -y nodejs
node -v && npm -v
```

## 8. Clone the repo (with submodules)

```sh
git clone --recurse-submodules https://github.com/fdimitri/carbide2-server.git
cd carbide2-server

# If you forgot --recurse-submodules:
git submodule update --init --recursive
```

## 9. Bring up the cluster

```sh
./scripts/dev-cluster.sh
```

This is idempotent — re-running it is safe. It will:

1. Create a k3d cluster `carbide-dev`, binding host `localhost:8080`
   and `localhost:8443` to the cluster's HTTP/HTTPS load balancer.
2. Install Rancher's `local-path-provisioner` and mark it the default
   StorageClass.
3. Install Traefik (the ingress controller).
4. Install the CloudNativePG operator.
5. Apply `deploy/cnpg-cluster.yaml` and wait for the shared Postgres
   cluster to become Ready.

When it finishes you should see `kubectl get nodes` print one Ready
node and `kubectl get pods -A` show everything `Running`.

## 10. Build and import the workspace image

The dev cluster runs containers from a local image. There is no
registry, so after every code change to the server you rebuild and
re-import:

```sh
docker build -t carbide2:dev .
k3d image import carbide2:dev -c carbide-dev
```

## 11. Install a workspace

```sh
helm upgrade --install ws-1 charts/workspace \
  -n ws-1 --create-namespace \
  --set projectId=1
kubectl -n ws-1 rollout status deploy/ws-1 --timeout=5m
```

Browse to <http://localhost:8080/w/1/> — you should get the Rails
welcome page. <http://localhost:8080/w/1/up> is the health endpoint
(returns a page with `background-color: green`).

## 12. Run the substrate tests

```sh
./scripts/test-substrate.sh
```

Layers, in order: bash smoke → `helm test` → Rails minitest in the pod
→ Playwright against the live workspace. Exit code is non-zero on the
first failure.

## 13. Day-to-day shortcuts

```sh
k3d cluster stop  carbide-dev      # pause (state preserved on disk)
k3d cluster start carbide-dev      # resume
k3d cluster delete carbide-dev     # nuke everything cluster-side

# Iterate on server code:
docker build -t carbide2:dev . && \
  k3d image import carbide2:dev -c carbide-dev && \
  kubectl -n ws-1 rollout restart deploy/ws-1
```

See [KUBE.md](KUBE.md) for a quick orientation to what the cluster is
made of and how to inspect it.
