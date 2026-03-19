# OpenG2P Automated Deployment

Automated single-node deployment of the complete OpenG2P platform — from bare Ubuntu to running modules.

## Two-Script Architecture

| Script | Purpose | Run when |
|---|---|---|
| `openg2p-infra.sh` | Base infrastructure (K8s, Istio, Rancher, Keycloak, monitoring) | Once per machine |
| `openg2p-environment.sh` | Environment + modules (namespace, commons, Registry, PBMS, etc.) | Once per environment |

## Domain Modes

The infrastructure script supports two modes — set `domain_mode` in your config:

| Mode | When to use | What you need | DNS | TLS |
|---|---|---|---|---|
| **`local`** | Sandboxes, demos, pilots, air-gapped, evaluation | Just a VM + its IP address | dnsmasq on the VM (auto-installed) | Local CA + self-signed certs (auto-generated) |
| **`custom`** (default) | Production, public-facing portals | Domain names + DNS records | Your DNS provider | Let's Encrypt (DNS-01 challenge) |

### Local mode (`domain_mode: local`)

Designed for getting OpenG2P running the same day, with zero external dependencies. The script installs `dnsmasq` on the VM to resolve `*.openg2p.test` to the VM's IP, generates a local Certificate Authority with self-signed certs, and configures Wireguard to push the VM as the DNS server. Once a user connects via Wireguard VPN, their laptop automatically resolves all OpenG2P hostnames.

Hostnames are auto-derived: `rancher.openg2p.test`, `keycloak.openg2p.test`, and later `registry.dev.openg2p.test`, etc.

**What the DevOps person needs to do on their laptop** (after the script completes):

1. **Install Wireguard** and import the peer config from the VM (`/etc/wireguard/peers/peer1/peer1.conf`). The config includes `DNS = <node_ip>` so all `*.openg2p.test` domains resolve automatically when the VPN is active.

2. **Install the CA certificate** to avoid browser warnings. Copy `/etc/openg2p/ca/ca.crt` from the VM to your laptop, then:
   - **macOS**: Open Keychain Access → File → Import Items → select `ca.crt` → drag to "System" keychain → double-click → Trust → set "Always Trust"
   - **Windows**: Double-click `ca.crt` → Install Certificate → Local Machine → "Trusted Root Certification Authorities"
   - **Linux**: `sudo cp ca.crt /usr/local/share/ca-certificates/openg2p-ca.crt && sudo update-ca-certificates`

Can be migrated to `custom` mode later when real domain names are available.

### Custom mode (`domain_mode: custom`)

For production deployments with proper domain names. Requires DNS A records pointing to the VM and uses Let's Encrypt for trusted TLS certificates.

Certificate challenge methods (set `letsencrypt_challenge` in config):

| Method | Config value | How it works |
|---|---|---|
| **Manual DNS** (default) | `dns` | Script pauses, shows TXT record to create, waits for confirmation |
| **Cloudflare automated** | `dns-cloudflare` | Fully automated via Cloudflare API token |
| **Route53 automated** | `dns-route53` | Fully automated via AWS credentials |
| **HTTP challenge** | `http` | Requires port 80 open to internet |

## Prerequisites

| Requirement | Local mode | Custom mode |
|---|---|---|
| **VM** | Ubuntu 24.04 LTS, 16 vCPU, 64 GB RAM, 128 GB SSD | Same |
| **Access** | Root/sudo on the VM | Same |
| **Internet** | Required for downloading packages and Helm charts | Same |
| **DNS** | Not needed (dnsmasq handles it) | A records for Rancher + Keycloak hostnames |
| **TLS** | Not needed (local CA handles it) | DNS access for TXT records (Let's Encrypt) |

## Quick Start

SSH into the VM as root:

```bash
git clone https://github.com/OpenG2P/openg2p-deployment.git
cd openg2p-deployment/automation
cp infra-config.example.yaml infra-config.yaml
# Edit infra-config.yaml — for local mode, just set node_ip and domain_mode: local
sudo chmod +x openg2p-infra.sh
sudo ./openg2p-infra.sh --config infra-config.yaml
```

**Local mode minimal config** — only 3 fields needed:
```yaml
node_ip: "172.16.0.10"    # Your VM's IP
node_name: "openg2p"
domain_mode: "local"
```

Takes ~15-25 minutes. Idempotent — re-run on failure.

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

1. Set up Wireguard VPN on your laptop (see peer config location in the summary output)
2. If local mode: install the CA certificate on your laptop (see instructions above)
3. Open Rancher and bootstrap admin password
4. Integrate Rancher with Keycloak ([OIDC guide](https://docs.openg2p.org/deployment/deployment-instructions/infrastructure-setup#id-11.-integrating-rancher-with-keycloak))
5. Run `openg2p-environment.sh` to create an OpenG2P environment (coming soon)

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

**Local DNS not resolving on my laptop?**
Ensure Wireguard VPN is connected. The DNS push only works when the VPN is active. Test with: `dig rancher.openg2p.test @<node_ip>`

**Browser shows certificate warning in local mode?**
Install the CA certificate on your laptop (see Local mode section above).

**Check cluster status:**
```bash
kubectl get nodes                              # Node health
kubectl get pods -A | grep -v Running          # Problem pods
helm list -A                                    # Helm releases
journalctl -u rke2-server -n 50               # RKE2 logs
```

## Rancher UI Path

This automation does not replace the Rancher UI. Your existing umbrella Helm charts with `questions.yml` continue to work for manual installs via the Rancher App Catalog.
