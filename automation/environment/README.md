# OpenG2P Multi-Node Environment Setup

Creates an OpenG2P environment (namespace + services) on an **existing multi-node infrastructure** where Nginx, the Kubernetes cluster, and storage run on separate nodes.

For single-node deployments, see [`../single-node/`](../single-node/).

## Architecture

```
                          ┌─────────────────────┐
                          │    DNS Provider      │
                          │  qa.openg2p.org  ──┐ │
                          │  *.qa.openg2p.org ─┘ │
                          └────────┬─────────────┘
                                   │ A records
                                   ▼
┌──────────────────────────────────────────────────────────────┐
│  Nginx Node                                                  │
│                                                              │
│  env-nginx.sh runs here (sudo):                              │
│    • certbot → Let's Encrypt wildcard cert                   │
│    • Nginx server block → proxy to Istio ingress             │
│                                                              │
│  /etc/nginx/sites-enabled/openg2p-env-qa.conf                │
│  /etc/letsencrypt/live/qa.openg2p.org/                       │
└──────────────────────┬───────────────────────────────────────┘
                       │ proxy_pass http://istio_ingress
                       ▼
┌──────────────────────────────────────────────────────────────┐
│  Kubernetes Cluster Node(s)                                  │
│                                                              │
│  env-cluster.sh targets here (via kubectl from workstation): │
│    • Namespace: qa                                           │
│    • Rancher Project: qa                                     │
│    • Istio Gateway: *.qa.openg2p.org                         │
│    • Keycloak secret                                         │
│    • Helm: openg2p-commons-base                              │
│    • Helm: openg2p-commons-services                          │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│  Storage Node (pre-existing)                                 │
│    • PostgreSQL                                              │
│    • MinIO                                                   │
└──────────────────────────────────────────────────────────────┘
```

## Prerequisites

- **Infrastructure already deployed** — Nginx node, K8s cluster, Istio, Rancher, Keycloak are all running.
- **Nginx node** — `certbot` installed, `nginx` running, `istio_ingress` upstream already configured.
- **Workstation** — `kubectl` and `helm` installed, kubeconfig with admin access to the cluster.
- **DNS access** — ability to create A records and TXT records at your DNS provider.

## Quick Start

### 1. Prepare config

```bash
cp env-config.example.yaml env-config.yaml
# Edit env-config.yaml with your values
```

Copy the same `env-config.yaml` to both the Nginx node and your workstation.

### 2. Create DNS records (manual)

At your DNS provider, create:

| Type | Name | Value |
|------|------|-------|
| A | `qa.openg2p.org` | `<nginx_node_ip>` |
| A | `*.qa.openg2p.org` | `<nginx_node_ip>` |

Wait for propagation (`dig qa.openg2p.org` should return the IP).

### 3. Run on Nginx node

SSH into the Nginx node and run:

```bash
sudo ./env-nginx.sh --config env-config.yaml
```

This will:
- Run `certbot` with DNS-01 challenge — **you will be prompted to create TXT records**
- Create the Nginx server block for `*.qa.openg2p.org` → Istio ingress

### 4. Run from workstation

From your workstation (with kubectl access):

```bash
./env-cluster.sh --config env-config.yaml
```

This will:
1. Create the K8s namespace
2. Create a Rancher Project and associate the namespace
3. Create the Istio Gateway
4. Create the Keycloak client-manager secret
5. Install `openg2p-commons-base` (PostgreSQL, Kafka, MinIO, Redis, etc.)
6. Install `openg2p-commons-services` (eSignet, Superset, ODK, etc.)

## File Structure

```
environment/
├── env-nginx.sh              # Run on Nginx node (sudo)
├── env-cluster.sh            # Run from workstation (kubectl/helm)
├── env-config.example.yaml   # Example config — copy and edit
├── lib/
│   └── utils.sh              # Shared utilities (logging, config parser)
└── .gitignore                # Ignores env-config.yaml
```

## Configuration Reference

All settings are in `env-config.yaml`. Both scripts read the same file.

| Key | Used by | Description |
|-----|---------|-------------|
| `environment` | both | Environment name (e.g., `qa`, `dev`, `staging`) |
| `base_domain` | both | Base domain (e.g., `qa.openg2p.org`) |
| `letsencrypt_email` | nginx | Email for Let's Encrypt registration |
| `letsencrypt_challenge` | nginx | Challenge type: `dns`, `dns-cloudflare`, `dns-route53` |
| `keycloak_hostname` | cluster | Keycloak hostname (e.g., `keycloak.openg2p.org`) |
| `keycloak.client_manager_user` | cluster | Keycloak client-manager username |
| `keycloak.client_manager_password` | cluster | Keycloak client-manager password |
| `commons_base.*` | cluster | Chart settings for openg2p-commons-base |
| `commons_services.*` | cluster | Chart settings for openg2p-commons-services |
| `modules.commons` | cluster | Enable/disable commons installation |

## CLI Options

### env-nginx.sh

```
sudo ./env-nginx.sh --config env-config.yaml [options]

Options:
  --config <file>    Config file (required)
  --force            Re-obtain certificate even if it exists
  --help             Show help
```

### env-cluster.sh

```
./env-cluster.sh --config env-config.yaml [options]

Options:
  --config <file>    Config file (required)
  --step <1-6>       Run only a specific step
  --force            Uninstall and reinstall Helm charts
  --help             Show help
```

## Creating Multiple Environments

To create additional environments (e.g., `staging`) on the same cluster:

1. Create a new config file with `environment: staging` and `base_domain: staging.openg2p.org`
2. Add DNS records for `staging.openg2p.org` and `*.staging.openg2p.org`
3. Run `env-nginx.sh` on the Nginx node with the new config
4. Run `env-cluster.sh` from your workstation with the new config

Each environment gets its own namespace, Rancher project, Istio gateway, and full set of services.

## Idempotency

Both scripts are safe to re-run:

- **env-nginx.sh** — skips certificate if already exists (use `--force` to re-obtain)
- **env-cluster.sh** — checks for existing namespace, project, gateway, secret, and Helm releases before creating. Use `--force` to tear down and reinstall Helm charts.

## Troubleshooting

### Certificate issues

```bash
# Check if cert exists
sudo ls -la /etc/letsencrypt/live/qa.openg2p.org/

# Test renewal
sudo certbot renew --dry-run

# Check TXT record propagation
dig TXT _acme-challenge.qa.openg2p.org
```

### Nginx issues

```bash
# Test config syntax
sudo nginx -t

# Check the generated server block
cat /etc/nginx/sites-enabled/openg2p-env-qa.conf

# Check if upstream exists
grep -r "istio_ingress" /etc/nginx/
```

### Cluster issues

```bash
# Verify kubectl access
kubectl cluster-info
kubectl get nodes

# Check namespace and pods
kubectl get pods -n qa
kubectl get pods -n qa --field-selector=status.phase!=Running

# Check Helm releases
helm list -n qa

# Check Istio gateway
kubectl get gateway -n qa

# Check Rancher project
kubectl get projects.management.cattle.io -n local -o json | jq '.items[] | {name: .metadata.name, display: .spec.displayName}'
```
