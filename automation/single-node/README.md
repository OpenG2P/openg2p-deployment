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

Designed for getting OpenG2P running the same day, with zero external dependencies. The script installs `dnsmasq` on the VM to resolve `*.openg2p.test` to the VM's IP, generates a local Certificate Authority with self-signed certs, and configures Wireguard VPN with split tunnel (only cluster traffic routed through VPN). After connecting via Wireguard, follow the post-install steps to configure DNS resolution and install the CA certificate on your laptop.

Hostnames are auto-derived: `rancher.openg2p.test`, `keycloak.openg2p.test`, and later `registry.dev.openg2p.test`, etc.

After the script completes, follow the [Post-Infrastructure Steps](#post-infrastructure-steps-on-your-laptop) below to set up Wireguard VPN, DNS resolution, CA certificate, and kubectl access on your laptop.

Can be migrated to `custom` mode later when real domain names are available.

### Custom mode (`domain_mode: custom`)

For production deployments with proper domain names. Requires DNS A records pointing to the VM.

TLS certificates can be obtained in two ways (`tls.method` in config):

| Method | Config value | How it works |
|---|---|---|
| **Let's Encrypt** (default) | `letsencrypt` | Auto-obtain certs. Set `tls.letsencrypt_email` and challenge method |
| **User-provided** | `provided` | Bring your own certs. Set `tls.rancher_cert`, `tls.rancher_key`, etc. |

When using Let's Encrypt, choose a challenge method (`tls.letsencrypt_challenge`):

| Challenge | Config value | How it works |
|---|---|---|
| **Manual DNS** (default) | `dns` | Script pauses, shows TXT record to create, waits for confirmation |
| **Cloudflare automated** | `dns-cloudflare` | Fully automated via Cloudflare API token |
| **Route53 automated** | `dns-route53` | Fully automated via AWS credentials |
| **HTTP challenge** | `http` | Requires port 80 open to internet |

When using user-provided certs, the script validates that the cert matches the hostname and that the cert and key are a matching pair. Wildcard certs are supported — set `tls.rancher_cert`/`tls.rancher_key` and leave keycloak paths empty to reuse the same cert for both.

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
cd openg2p-deployment/automation/single-node
cp infra-config.example.yaml infra-config.yaml
# Edit infra-config.yaml — for local mode, just set node_ip and domain_mode: local
sudo chmod +x openg2p-infra.sh
sudo ./openg2p-infra.sh --config infra-config.yaml
```

**Local mode minimal config** — only `node_ip` is required (everything else has defaults):
```yaml
node_ip: "172.16.0.10"       # Your VM's private IP
domain_mode: "local"
cluster_name: "openg2p"      # Display name in Rancher UI (default: openg2p)
node_name: "node1"           # K8s node name (default: node1)
keycloak:
  admin_email: "admin@example.com"  # For Rancher-Keycloak SSO
```

For AWS or any setup where the public IP differs from `node_ip`, also set:
```yaml
wireguard:
  endpoint: "<public-ip>"     # Public IP for VPN clients
```

Takes ~15-25 minutes. Idempotent — re-run on failure.

### AWS EC2: Security Group Setup

Before running the script on an EC2 instance, create and attach the required security group:

```bash
cd automation/single-node/aws
./create-security-group.sh --vpc-id vpc-xxxxxxxxx [--region ap-south-1]
```

This creates a security group called `openg2p-single-node` with all the ports needed for OpenG2P (SSH, HTTPS, Wireguard, K8s API, etcd, CNI, NodePorts). Inter-node ports are scoped to the VPC CIDR for multi-node readiness.

After creation, attach it to your instance and disable source/destination check (required for Wireguard):

```bash
aws ec2 modify-instance-attribute --instance-id i-xxxxxxxxx --groups sg-xxxxxxxxx
aws ec2 modify-instance-attribute --instance-id i-xxxxxxxxx --no-source-dest-check
```

The script auto-detects the VPC CIDR. Run `./create-security-group.sh --help` for all options.

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

The default is **split tunnel** — only Wireguard subnet + VPC traffic routes through the VPN, your internet stays direct and fast.

### Step 2: DNS resolution (local mode only)

In local mode, the VM's dnsmasq resolves `*.openg2p.test` hostnames. The peer config includes the VM as a DNS server, which works on most platforms. For reliable resolution, also configure per-domain DNS on your laptop:

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

This ensures `*.openg2p.test` queries go to the VM's dnsmasq while all other DNS stays normal.

> **Note:** `dig` bypasses the macOS resolver system. Use `dscacheutil -q host -a name rancher.openg2p.test` or `ping` or `curl` to verify DNS on macOS.

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

**Keycloak login (recommended):** Click "Login with Keycloak" and use the email address configured in `keycloak.admin_email` (default: `admin@openg2p.org`) as the username. The Keycloak admin password is stored in the K8s secret `keycloak-system/keycloak` (key: `admin-password`):
```bash
sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml kubectl -n keycloak-system get secret keycloak -o jsonpath='{.data.admin-password}' | base64 -d && echo
```

**Local admin login:** Rancher also has a built-in local admin account with username **`admin`**. The password is auto-generated and saved to K8s secret `cattle-system/rancher-secret`:
```bash
sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml kubectl -n cattle-system get secret rancher-secret -o jsonpath='{.data.adminPassword}' | base64 -d && echo
```

To override the Rancher admin password on re-runs:
```bash
sudo RANCHER_ADMIN_PASSWORD=mypassword ./openg2p-infra.sh --config infra-config.yaml --phase 3
```

### Step 6: User Access & Roles

Rancher ships with built-in project roles (`Project Owner`, `Project Member`, `Read-Only`), but all of them include full access to Kubernetes Secrets. Since secrets contain database passwords, API keys, and other sensitive data, this script creates two additional custom roles that exclude secrets access:

| Role | Source | Secrets Access | Permissions |
|---|---|---|---|
| **Project Owner** | Rancher built-in | Full | Full control of the project and all its namespaces |
| **Project Member** | Rancher built-in | Full | Create/edit/delete workloads, services, configs, secrets |
| **Project Member (No Secrets)** | Created by this script | None | Same as Project Member, but cannot view or manage secrets |
| **Project Read-Only (No Secrets)** | Created by this script | None | View-only access to workloads, services, configs — no secrets |

**To give a user access to an environment:**

1. Create the user in **Keycloak** (Admin Console → Users → Add user). Use their email as the username.
2. In **Rancher**, go to the Project (environment) → Members → Add Member.
3. Search for the user by email and assign one of the roles above.

The user can then log in to Rancher via "Login with Keycloak" using their email address.

> **Note:** The Rancher `admin` global role (super admin) has access to everything. The initial admin user configured during setup already has this role.

### Step 7: Create an Environment

After the infrastructure is ready, create one or more environments using `openg2p-environment.sh`. Each environment is an isolated namespace with its own domain, services, and user access.

```bash
cp env-config.example.yaml env-config.yaml
# Edit env-config.yaml — for local mode, just set environment name
sudo ./openg2p-environment.sh --config env-config.yaml
```

**Local mode minimal config** — everything else is auto-derived from the infra config:
```yaml
environment: "dev"
infra_config: "infra-config.yaml"
modules:
  commons: true
```

This creates namespace `dev` with domain `dev.openg2p.test` and installs openg2p-commons (PostgreSQL, Kafka, MinIO, OpenSearch, Superset, eSignet, ODK, etc.). Services become available at `minio.dev.openg2p.test`, `superset.dev.openg2p.test`, etc.

**Custom mode** — set `base_domain` and Keycloak credentials explicitly:
```yaml
environment: "dev"
base_domain: "dev.openg2p.org"
infra_config: "infra-config.yaml"
modules:
  commons: true
```

**Multiple environments** — run the script multiple times with different configs:
```bash
sudo ./openg2p-environment.sh --config env-dev.yaml    # dev.openg2p.test
sudo ./openg2p-environment.sh --config env-qa.yaml     # qa.openg2p.test
sudo ./openg2p-environment.sh --config env-pilot.yaml  # pilot.openg2p.test
```

Takes ~15-20 minutes per environment. Idempotent — re-run on failure.

See [Environment Setup Details](#environment-setup-details) below for the full phase breakdown.

## Environment Setup Details

The `openg2p-environment.sh` script runs in two phases:

### Phase 1: Environment Infrastructure

| Step | What | Details |
|---|---|---|
| E1.1 | Validate prerequisites | Infra completed, kubeconfig works, base domain available |
| E1.2 | TLS certificate | **Local:** wildcard cert `*.dev.openg2p.test` signed by existing CA. **Custom:** Let's Encrypt wildcard cert |
| E1.3 | Nginx server block | Adds `*.dev.openg2p.test` → Istio ingress (separate config file per environment) |
| E1.4 | K8s namespace | Creates the namespace if it doesn't exist |
| E1.5 | Rancher Project | Creates a Rancher Project and moves the namespace into it (for RBAC) |
| E1.6 | Istio Gateway | Creates Istio Gateway resource for hostname routing |

### Phase 2: Module Installation

openg2p-commons is split into two Helm charts installed sequentially:

| Step | What | Details |
|---|---|---|
| E2.1 | openg2p-commons-base | Infrastructure layer: PostgreSQL, Kafka, MinIO, OpenSearch, Redis, SoftHSM, keycloak-init, postgres-init |
| E2.2 | openg2p-commons-services | Application layer: eSignet, KeyManager, Superset, ODK, master-data, reporting, mock-identity-system. Depends on base for DB/cache/storage connectivity |
| *(future)* | Registry, PBMS, SPAR, G2P Bridge | Placeholder steps — will be added as separate Helm installs |

The services chart automatically connects to base infrastructure via `global.postgresqlHost`, `global.redisInstallationName`, etc. derived from the base release name (`commons-base`).

### Environment Command Options

```bash
sudo ./openg2p-environment.sh --config env-config.yaml              # Full setup
sudo ./openg2p-environment.sh --config env-config.yaml --phase 1    # Infrastructure only
sudo ./openg2p-environment.sh --config env-config.yaml --phase 2    # Module install only
sudo ./openg2p-environment.sh --config env-config.yaml --force       # Re-run everything
```

### Migrating from Local to Custom Domain

When your sandbox is ready for a real domain name, migrate without reinstalling:

```bash
cp migrate-config.example.yaml migrate-config.yaml
# Edit: set new_rancher_hostname, new_keycloak_hostname, letsencrypt_email
# List environments to migrate with their new base_domain
sudo ./openg2p-migrate-domain.sh --config migrate-config.yaml
```

This is a **non-destructive** operation — no data loss, no service reinstall. It:
- Validates DNS records for new hostnames
- Obtains Let's Encrypt certificates
- Updates Nginx, Keycloak, Rancher, SAML, Istio Gateway
- Helm upgrades each environment's commons charts with new domain
- Updates infra-config.yaml and env-config.yaml (backups: `*.pre-migration`)
- Removes CoreDNS local domain forward

After migration, you can remove `/etc/resolver` entries and the self-signed CA from your laptop.

### Uninstalling

**Remove a single environment** (keeps infrastructure and other environments intact):
```bash
sudo ./openg2p-environment-uninstall.sh --config env-config.yaml
```

This permanently deletes: Helm releases, databases, secrets, PVCs/PVs, Istio Gateway, Nginx config, Rancher Project, and the namespace.

**Remove the entire infrastructure** (destroys everything — all environments, the K8s cluster, VPN, DNS):
```bash
sudo ./openg2p-infra-uninstall.sh
```

Requires typing `DELETE EVERYTHING` to confirm. Removes: RKE2 cluster, Wireguard VPN, dnsmasq, Nginx, NFS exports, TLS certificates, and all state. The VM is left clean for a fresh installation.

## File Structure

```
automation/single-node/
├── openg2p-infra.sh                  # Script 1: base infrastructure
├── openg2p-infra-uninstall.sh        # Uninstall: tears down entire infrastructure
├── infra-config.example.yaml         # Config for Script 1
├── helmfile-infra.yaml.gotmpl        # Helmfile for platform components (Go template)
├── openg2p-environment.sh            # Script 2: environment setup
├── openg2p-environment-uninstall.sh  # Uninstall: removes a single environment
├── env-config.example.yaml           # Config for Script 2
├── openg2p-migrate-domain.sh         # Migrate: local → custom domain
├── migrate-config.example.yaml       # Config for domain migration
├── README.md
├── lib/
│   ├── utils.sh          # Shared: logging, state, config, wait helpers
│   ├── phase1.sh         # Infra Phase 1: host setup (tools, RKE2, Wireguard, NFS, DNS, TLS, Nginx)
│   ├── phase2.sh         # Infra Phase 2: platform components (Istio, Helmfile sync)
│   ├── phase3.sh         # Infra Phase 3: Rancher-Keycloak SAML, roles
│   ├── env-phase1.sh     # Env Phase 1: certs, Nginx, namespace, Rancher project, Istio GW
│   └── env-phase2.sh     # Env Phase 2: commons helm install (future: more modules)
├── aws/
│   ├── create-security-group.sh   # Creates "openg2p-single-node" SG via AWS CLI
│   └── security-group.json        # Reference: exported SG rules
└── charts/
    ├── raw/               # Minimal chart for applying K8s manifests
    └── istio-install/     # Istio operator YAML for istioctl
```

## Troubleshooting

**Script failed — what do I do?**
Re-run it. Completed steps are skipped. Error messages include diagnostic commands.

**Local DNS not resolving on my laptop?**
Ensure Wireguard VPN is connected. Configure per-domain DNS on your laptop (see Step 2 above). On macOS, `dig` bypasses the resolver system — use `ping` or `dscacheutil -q host -a name rancher.openg2p.test` to test instead.

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
