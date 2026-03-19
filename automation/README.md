# OpenG2P Automated Deployment

Automated single-node deployment of the complete OpenG2P platform — from bare Ubuntu to running modules.

## Two-Script Architecture

| Script | Purpose | Run when |
|---|---|---|
| `openg2p-infra.sh` | Base infrastructure (K8s, Istio, Rancher, Keycloak, monitoring, Rancher-Keycloak SSO) | Once per machine |
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

After the script completes, follow the [Post-Infrastructure Steps](#post-infrastructure-steps-on-your-laptop) below to set up Wireguard VPN, DNS resolution, CA certificate, and kubectl access on your laptop.

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

**Local mode minimal config** — only 4 fields needed:
```yaml
node_ip: "172.16.0.10"       # Your VM's private IP
node_name: "openg2p"
domain_mode: "local"
keycloak:
  admin_email: "admin@example.com"  # For Rancher-Keycloak SSO
```

For AWS or any setup where the public IP differs from `node_ip`, also set:
```yaml
wireguard:
  endpoint: "<public-ip>"     # Public IP for VPN clients
  cluster_subnet: "172.29.0.0/16"  # Split tunnel (recommended)
```

Takes ~15-25 minutes. Idempotent — re-run on failure.

## Command Options

```bash
sudo ./openg2p-infra.sh --config infra-config.yaml              # Full infra setup
sudo ./openg2p-infra.sh --config infra-config.yaml --phase 1    # Host setup only
sudo ./openg2p-infra.sh --config infra-config.yaml --phase 2    # Helmfile only
sudo ./openg2p-infra.sh --config infra-config.yaml --phase 3    # Rancher-Keycloak integration only
sudo ./openg2p-infra.sh --config infra-config.yaml --force       # Re-run everything
sudo ./openg2p-infra.sh --config infra-config.yaml --dry-run     # Preview
sudo ./openg2p-infra.sh --reset                                   # Clear state markers
```

## Post-Infrastructure Steps (on your laptop)

After the script completes, follow these steps to access the cluster from your machine.

### Step 1: Wireguard VPN

Copy the peer config from the VM to your laptop:

```bash
# On the VM:
sudo cp /etc/wireguard/peers/peer1/peer1.conf /tmp/
sudo chmod 644 /tmp/peer1.conf

# On your laptop:
scp -i <your-key.pem> <user>@<public-ip>:/tmp/peer1.conf .
```

If the VM has a public IP different from `node_ip` (e.g., AWS with a public + private IP), edit `peer1.conf` and change the `Endpoint` line to the public IP. Or set `wireguard.endpoint` in your config before running the script.

Import `peer1.conf` into the [Wireguard client app](https://www.wireguard.com/install/) on your laptop and activate the tunnel.

**Important for split tunnel:** If you set `wireguard.cluster_subnet` to a specific subnet (not `0.0.0.0/0`), the `AllowedIPs` in the peer config will only route cluster traffic through the VPN — your internet stays normal. However, you'll need per-domain DNS (see Step 2).

### Step 2: DNS resolution (local mode + split tunnel only)

If you're using `domain_mode: local` with split tunnel (`cluster_subnet` set), the Wireguard `DNS` directive is not included (it would break your internet). Configure per-domain DNS instead:

**macOS:**
```bash
sudo mkdir -p /etc/resolver
echo "nameserver <node_ip>" | sudo tee /etc/resolver/<local_domain>
# e.g.: echo "nameserver 172.29.8.137" | sudo tee /etc/resolver/sandbox.test
```

**Windows (PowerShell as Administrator):**
```powershell
Add-DnsClientNrptRule -Namespace ".<local_domain>" -NameServers "<node_ip>"
# e.g.: Add-DnsClientNrptRule -Namespace ".sandbox.test" -NameServers "172.29.8.137"
```

**Linux:**
```bash
sudo resolvectl dns wg0 <node_ip>
sudo resolvectl domain wg0 '~<local_domain>'
```

Note: `dig` bypasses the macOS resolver system. Use `dscacheutil -q host -a name rancher.<local_domain>` or `ping` or `curl` to test DNS on macOS.

### Step 3: CA certificate (local mode only)

Copy `/etc/openg2p/ca/ca.crt` from the VM to your laptop, then install it:

**macOS:**
```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ca.crt
```
Or double-click `ca.crt` and install via System Settings → General → Profiles.

**Windows:** Double-click `ca.crt` → Install Certificate → Local Machine → "Trusted Root Certification Authorities"

**Linux:**
```bash
sudo cp ca.crt /usr/local/share/ca-certificates/openg2p-ca.crt
sudo update-ca-certificates
```

### Step 4: kubectl / helm access

The script generates a remote-access kubeconfig at `/etc/rancher/rke2/rke2-remote.yaml` (with the VM's private IP instead of `127.0.0.1`).

```bash
# On the VM:
sudo cp /etc/rancher/rke2/rke2-remote.yaml /tmp/
sudo chmod 644 /tmp/rke2-remote.yaml

# On your laptop:
scp -i <your-key.pem> <user>@<public-ip>:/tmp/rke2-remote.yaml ~/.kube/openg2p-config
export KUBECONFIG=~/.kube/openg2p-config
kubectl get nodes
```

Requires Wireguard VPN to be active (the K8s API is on the private IP).

### Step 5: Login to Rancher

Rancher-Keycloak SAML integration is done automatically by the script (Phase 3). Open Rancher at `https://rancher.<domain>` — you should see a **"Login with Keycloak"** button.

Login using the Keycloak admin email configured in `keycloak.admin_email` (default: `admin@openg2p.org`). The Keycloak admin password is stored in the K8s secret `keycloak-system/keycloak` (key: `admin-password`).

The Rancher admin password is auto-generated and saved to K8s secret `cattle-system/rancher-secret`. To retrieve it:
```bash
sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml kubectl -n cattle-system get secret rancher-secret -o jsonpath='{.data.adminPassword}' | base64 -d && echo
```

To override the Rancher admin password on re-runs:
```bash
sudo RANCHER_ADMIN_PASSWORD=mypassword ./openg2p-infra.sh --config infra-config.yaml --phase 3
```

### Step 6: Next

Run `openg2p-environment.sh` to create an OpenG2P environment (coming soon).

## File Structure

```
automation/
├── openg2p-infra.sh               # Script 1: base infrastructure
├── infra-config.example.yaml      # Config for Script 1
├── helmfile-infra.yaml.gotmpl     # Helmfile for platform components (Go template)
├── openg2p-environment.sh         # Script 2: environment setup (coming soon)
├── env-config.example.yaml        # Config for Script 2
├── helmfile-env.yaml              # Helmfile for environment modules
├── README.md
├── lib/
│   ├── utils.sh                   # Shared: logging, state, config, wait helpers
│   ├── phase1.sh                  # Phase 1: host-level setup (tools, RKE2, Wireguard, NFS, DNS, TLS, Nginx)
│   ├── phase2.sh                  # Phase 2: platform components (Istio, Helmfile sync)
│   └── phase3.sh                  # Phase 3: Rancher-Keycloak SAML integration
└── charts/
    ├── raw/                       # Minimal chart for applying K8s manifests
    └── istio-install/             # Istio operator YAML for istioctl
```

## Troubleshooting

**Script failed — what do I do?**
Re-run it. Completed steps are skipped. Error messages include diagnostic commands.

**Local DNS not resolving on my laptop?**
Ensure Wireguard VPN is connected. If using split tunnel, configure per-domain DNS (see Step 2 above). Note: `dig` bypasses the macOS resolver — use `ping` or `dscacheutil` to test instead.

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
