# Carbide2 Server — Installation

The workspace image built from this repo does not run on its own. A workspace
is a `Workspace` custom resource reconciled by the control operator, which
provisions the pod, its PVC, its database credentials, its ingress, and its
shell (ADR-016, ADR-029). There is no docker-compose stack and no bare-metal
mode (ADR-031).

Install the control plane and a cluster from the meta repo:

- [`carbide2/INSTALL.md`](https://github.com/fdimitri/carbide2/blob/main/INSTALL.md)
  — prerequisites and `scripts/deploy.rb`
- [`DEPLOY-k3d.md`](DEPLOY-k3d.md) in this repo — day-to-day cluster shortcuts
- [`README.md`](README.md) § Development — the build → import → deploy loop for
  this image

## Running tests

```bash
# Rails unit/model tests
bundle exec rails test

# Playwright e2e (against a running workspace, run on the host)
cd ../carbide2-client   # or wherever you cloned carbide2-client
npx playwright install --with-deps   # one-time
npx playwright test --reporter=list
```
