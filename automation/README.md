# OpenG2P Automated Deployment

Automated single-node deployment of the complete OpenG2P platform — from bare Ubuntu to running modules.

## Two-Script Architecture

| Script | Purpose | Run when |
|---|---|---|
| `openg2p-infra.sh` | Base infrastructure (K8s, Istio, Rancher, Keycloak, monitoring) | Once per machine |
| `openg2p-environment.sh` | Environment + modules (namespace, commons, Registry, PBMS, etc.) | Once per environment |

### Script 1: `openg2p-infra.sh` — Base Infrastructure

Matches [Infrastructure Setup](https://docs.openg2p.org/deployment/deployment-instructions/infrastructure-setup) docs.

**Phase 1 (bash on host):** tools, firewall, RKE2, Wireguard, NFS, Let's Encrypt certs (DNS-01), Nginx

**Phase 2 (Helmfile on K8s):** Istio, Rancher + ingress, Keycloak + ingress, Prometheus/Grafana, FluentD logging

After this completes you have a working K8s platform with Rancher UI and Keycloak — but zero OpenG2P modules.

### Script 2: `openg2p-environment.sh` — Environment Setup *(coming soon)*

Matches [Environment Installation](https://docs.openg2p.org/deployment/deployment-instructions/environment-installation) docs.

Creates a Kubernetes namespace, adds environment-specific Istio gateway, TLS certs, Nginx server block, and installs openg2p-commons + selected modules (Registry, PBMS, SPAR, G2P Bridge). Can be run multiple times for different environments (dev, qa, pilot).

## Prerequisites

| Requirement | Details |
|---|---|
| **VM** | Ubuntu 24.04 LTS, 16 vCPU, 64 GB RAM, 128 GB SSD |
| **Access** | Root/sudo on the VM |
| **DNS** | A records for Rancher and Keycloak hostnames pointing to the VM's IP |
| **Internet** | Required for packages, Helm charts, Let's Encrypt |
| **DNS access** | Ability to create TXT records at your DNS provider (for Let's Encrypt DNS-01 challenge) |

## Quick Start — Infrastructure

SSH into the VM as root:

```bash
git clone https://github.com/OpenG2P/openg2p-deployment.git
cd openg2p-deployment/automation
cp infra-config.example.yaml infra-config.yaml
# Edit infra-config.yaml with your values
sudo chmod +x openg2p-infra.sh
sudo ./openg2p-infra.sh --config infra-config.yaml
```

Takes ~15-25 minutes. Idempotent — re-run on failure.

## TLS Certificate Methods

The script uses **DNS-01 challenge by default** — it pauses and tells you exactly what TXT record to create at your DNS provider. This works even when port 80 is blocked, which is common in government/restricted environments.

Set `letsencrypt_challenge` in your config to choose a method:

| Method | Config value | How it works |
|---|---|---|
| **Manual DNS** (default) | `dns` | Script pauses, shows TXT record to create, waits for you to confirm |
| **Cloudflare automated** | `dns-cloudflare` | Fully automated via Cloudflare API token — no manual steps |
| **Route53 automated** | `dns-route53` | Fully automated via AWS credentials — no manual steps |
| **HTTP challenge** | `http` | Requires port 80 open to internet — simplest but least portable |

For Cloudflare automation, also set `cloudflare_api_token` in your config. The token needs "Zone:DNS:Edit" permission.

## Command Options

```bash
sudo ./openg2p-infra.sh --config infra-config.yaml              # Full infra setup
sudo ./openg2p-infra.sh --config infra-config.yaml --phase 1    # Host setup only
sudo ./openg2p-infra.sh --config infra-config.yaml --phase 2    # Helmfile only
sudo ./openg2p-infra.sh --config infra-config.yaml --force       # Re-run everything
sudo ./openg2p-infra.sh --config infra-config.yaml --dry-run     # Preview
sudo ./openg2p-infra.sh --reset                                   # Clear state markers
```

## Post-Infrastructure Steps

1. **Bootstrap Rancher admin**: Open `https://<rancher_hostname>`, set admin password
2. **Integrate Rancher with Keycloak**: [OIDC guide](https://docs.openg2p.org/deployment/deployment-instructions/infrastructure-setup#id-11.-integrating-rancher-with-keycloak)
3. **Configure Wireguard VPN**: Copy `/etc/wireguard_app_users/peer1/peer1.conf` to your laptop
4. **Create an environment**: Run `openg2p-environment.sh` (coming soon)

## File Structure

```
automation/
├── openg2p-infra.sh               # Script 1: base infrastructure
├── infra-config.example.yaml      # Config for Script 1
├── helmfile-infra.yaml            # Helmfile for platform components
├── openg2p-environment.sh         # Script 2: environment setup (coming soon)
├── env-config.example.yaml        # Config for Script 2
├── helmfile-env.yaml              # Helmfile for environment modules
├── README.md
├── lib/
│   ├── utils.sh                   # Shared: logging, state, config, wait helpers
│   └── phase1.sh                  # Infra Phase 1: host-level setup functions
└── charts/
    ├── raw/                       # Minimal chart for applying K8s manifests
    └── istio-install/             # Istio operator YAML for istioctl
```

## Troubleshooting

**Script failed — what do I do?**
Re-run it. Completed steps are skipped. Error messages include diagnostic commands.

**DNS-01 challenge failed?**
Verify the TXT record was created: `dig TXT _acme-challenge.<your-domain>`. DNS propagation can take a few minutes. Some DNS providers have a delay before records are queryable.

**Check cluster status:**
```bash
kubectl get nodes                              # Node health
kubectl get pods -A | grep -v Running          # Problem pods
helm list -A                                    # Helm releases
journalctl -u rke2-server -n 50               # RKE2 logs
```

## Rancher UI Path

This automation does not replace the Rancher UI. Your existing umbrella Helm charts with `questions.yml` continue to work for manual installs via the Rancher App Catalog.
