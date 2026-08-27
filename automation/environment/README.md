# OpenG2P Environment Automation (multi-node / Commons)

Scripts in this folder install and tear down an OpenG2P **environment** on an
existing Kubernetes cluster (namespace, Rancher project, Istio gateway, and
optionally Commons Helm charts).

## Relation to production automation

For **3-node production** (`automation/production/`):

- Production scaffolding (namespace, project, gateway, PG secret, ClusterRepos)
  is done by `openg2p-prod.sh --stage environment` / `roles/environment/phase1.sh`.
- **Commons is not installed by production scripts.** Prefer the Rancher UI.
- This folder is the **optional** scripted path for Commons after production
  scaffolding is complete.

See `automation/production/README.md` for the full production flow.

## Commons version

Before installing, pick the Commons chart version from the changelog:

https://openg2p.gitlab.io/versions/commons/CHANGELOG.html

Set the same version on both `commons_base.chart_version` and
`commons_services.chart_version` in `env-config.yaml`.

## Quick start

```bash
cd automation/environment
cp env-config.example.yaml env-config.yaml   # edit environment, base_domain, versions

./env-cluster.sh --config env-config.yaml
```

Requires `kubectl` / `helm` access to the cluster (for production, Wireguard or
an equivalent path to the private API is typically needed for day-2 scripted
Commons installs from your laptop).

## Uninstall / refresh

```bash
./env-cluster-uninstall.sh --namespace <env-name>
./env-cluster-uninstall.sh --namespace <env-name> --full   # also delete namespace
./env-refresh.sh --config env-config.yaml                  # uninstall + reinstall
```

## Scripts

| Script | Purpose |
|--------|---------|
| `env-cluster.sh` | Create namespace, Rancher project, Istio gateway; install commons-base + commons-services |
| `env-cluster-uninstall.sh` | Remove Helm releases / data in a namespace |
| `env-refresh.sh` | Uninstall then reinstall using the same config |

Helm chart repo default (see `env-config.example.yaml`):

`https://gitlab.com/api/v4/projects/84460547/packages/helm/stable`
