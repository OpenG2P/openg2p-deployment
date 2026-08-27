# OpenG2P 3-Node Production Automation

Scripts under `automation/production/` provision and configure a three-node
OpenG2P production platform (reverse-proxy, compute/RKE2, storage) and scaffold
an application environment.

**Commons is not installed by these scripts.** After scaffolding, install
Commons from the **Rancher UI only**.

## What the install does

| Stage | Where it runs | What it sets up |
|-------|---------------|-----------------|
| Storage phase 1 | storage node (SSH) | NFS server, host PostgreSQL |
| Compute phase 1 | compute node (SSH) | RKE2, NFS client, `/etc/hosts` for Rancher hostname |
| Reverse-proxy phase 1 | RP node (SSH) | Wireguard server, Nginx, TLS certs |
| Compute phase 2 | compute node (SSH) | Istio, Rancher, monitoring, logging (helmfile) |
| Environment phase 1 | laptop → cluster | Namespace, Rancher project, Istio gateway, PG secret, Helm ClusterRepos |

Environment kubectl access uses an **SSH tunnel** to the compute API
(`localhost → compute:127.0.0.1:6443`). **Wireguard is not required** for
environment scaffolding. Connect Wireguard later for Rancher UI and day-2
`kubectl` over the private network.

## Quick start

```bash
cd automation/production
cp prod-config.example.yaml prod-config.yaml   # edit USER / CUSTOMER values
# If using AWS: run aws/openg2p-aws-provision.sh first → writes provision-output.yaml

./openg2p-prod.sh --probe     --config prod-config.yaml
./openg2p-prod.sh --preflight --config prod-config.yaml
./openg2p-prod.sh             --config prod-config.yaml
```

### Environment only

```bash
./openg2p-prod.sh --stage environment --config prod-config.yaml
# or: ./openg2p-prod-env-install.sh --config prod-config.yaml
#     (wrapper → roles/environment/run.sh --phase 1)
```

Set `install_environment: false` in `prod-config.yaml` to skip the environment
stage during a full install; run it later with `--stage environment`.

### Environment uninstall

```bash
./openg2p-prod-env-uninstall.sh --config prod-config.yaml
# (wrapper → roles/environment/uninstall.sh)
```

## Keep these files secure

The production folder holds **live provisioning and cluster credentials**. Treat
everything below as secrets: restrict filesystem permissions, do not commit them
to git (most are already gitignored), and store copies in your organisation’s
secrets vault for disaster recovery and future day-2 operations.

### Must keep (required for future use)

| Path | Why it matters |
|------|----------------|
| **`provision-output.yaml`** | AWS-derived IPs, SSH hosts, Wireguard endpoint, subnet, peer DNS. The orchestrator overlays this on every re-run. |
| **`prod-config.yaml`** | Domain, cert paths, versions, `install_environment`, environment name. |
| **`artifacts/peer1.conf`** | Wireguard peer config (pulled at end of a successful install). |
| **`artifacts/rke2.yaml`** | Kubeconfig for day-2 use over Wireguard (API at compute private IP). |
| **`aws/keys/*.pem`** | SSH private keys for the three nodes. |
| **`certs/`** | Customer TLS fullchain + private key used by the reverse-proxy. |

### Also sensitive (keep locked down)

| Path | Why |
|------|-----|
| **`setup-output/SETUP-SUMMARY.txt`** | Plaintext Rancher admin and PostgreSQL superuser passwords. Copy into a vault. |
| **`aws/aws-config.yaml`** | AWS account/region/project settings. |
| **`.state/`** | Laptop orchestrator state (includes cached kubeconfig under `.state/environment/`). |
| **`logs/`** | May contain hostnames, IPs, and credential-adjacent output. |
| **`peer*.conf`** (folder root) | Legacy manual pull location; prefer `artifacts/`. |

Folder/file modes applied by the scripts where possible:

- `artifacts/` and `setup-output/` → directory `0700`, files `0600`
- SSH keys under `aws/keys/` → keep `0600`

**Do not** publish these files, commit them to a public repo, or share them over
unencrypted channels.

## Artifacts folder

After a full `./openg2p-prod.sh` run completes, the orchestrator pulls:

```text
artifacts/peer1.conf   # Wireguard — import into the Wireguard client
artifacts/rke2.yaml    # kubeconfig for day-2 use over Wireguard
```

Keep this folder secure. Re-pull manually if needed:

```bash
# peer1
ssh -i aws/keys/<key>.pem ubuntu@<rp-public-ip> \
  'sudo cat /etc/wireguard/peers/peer1/peer1.conf' > artifacts/peer1.conf

# kubeconfig (prefer the remote-rewritten file on compute)
ssh -i aws/keys/<key>.pem ubuntu@<compute-ssh-host> \
  'sudo cat /etc/rancher/rke2/rke2-remote.yaml' > artifacts/rke2.yaml
chmod 600 artifacts/peer1.conf artifacts/rke2.yaml
```

## Environment scripts (`roles/environment/`)

| File | Purpose |
|------|---------|
| `roles/environment/run.sh` | Install entry (`--phase 1`) |
| `roles/environment/phase1.sh` | Namespace, Rancher project, Istio gateway, PG secret, Helm repos (SSH tunnel — no Wireguard) |
| `roles/environment/uninstall.sh` | Tear down environment (Helm releases, PVCs, host DBs) |

Top-level wrappers:

- `openg2p-prod-env-install.sh` → `run.sh --phase 1`
- `openg2p-prod-env-uninstall.sh` → `uninstall.sh`

Gated by `install_environment: true/false` in `prod-config.yaml`.

During scaffolding the following Rancher CatalogV2 ClusterRepos are registered:

- `openg2p` — `https://openg2p.github.io/openg2p-helm/rancher` (Apps UI)
- `openg2p-gitlab` — `https://gitlab.com/api/v4/projects/84460547/packages/helm/stable`

## Commons installation (Rancher UI only)

Environment scaffolding does **not** install Commons. Install from the Rancher
UI after Wireguard is up and you can reach Rancher:

1. Rancher → Apps → Charts → `openg2p-commons-base`
2. Then install `openg2p-commons-services` (same namespace)
3. Point PostgreSQL at the storage private IP using secret `commons-postgresql`
4. Pick the Commons version from the changelog:  
   https://openg2p.gitlab.io/versions/commons/CHANGELOG.html

Do **not** use `automation/environment/` or Helm CLI scripts to install Commons
in production — those scripts only scaffold the namespace (if used standalone).

## Changing `public_domain` (or the Rancher hostname)

Rancher is probed from the **compute** node as `https://rancher.<public_domain>`.
Compute `/etc/hosts` and RP Nginx are written in earlier phases and skipped on
re-run when state markers say “done”.

If you change `public_domain` (for example from `prod.openg2p.org` to
`prodtest.openg2p.org`) on an existing install:

1. Ensure TLS certs cover the new hostname (or `*.<new-domain>`)
2. Force-rebuild the hostname-dependent steps:

```bash
./openg2p-prod.sh --config prod-config.yaml --role compute --phase 1 --force
./openg2p-prod.sh --config prod-config.yaml --role rp --phase 1 --force
./openg2p-prod.sh --config prod-config.yaml --role compute --phase 2 --force
```

Otherwise C2.4 may fail with `HTTP 000` (compute cannot resolve/reach the new
Rancher URL).

## Useful commands

```bash
./openg2p-prod.sh --config prod-config.yaml --stage environment
./openg2p-prod-env-uninstall.sh --config prod-config.yaml   # tear down env only
./openg2p-prod-uninstall.sh --config prod-config.yaml       # wipe node roles
```

Docs: [three-node automation](https://docs.openg2p.org/operations/deployment/automation/three-node-automation).
