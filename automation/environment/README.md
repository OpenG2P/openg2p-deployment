# OpenG2P Environment Setup for Multi-Node Configuration

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
│  Nginx Node                              (manual setup)      │
│                                                              │
│  • DNS A records → this node's IP                            │
│  • Let's Encrypt wildcard cert (certbot)                     │
│  • Nginx server block → proxy to Istio ingress               │
└──────────────────────┬───────────────────────────────────────┘
                       │ proxy_pass → http://istio_ingress
                       ▼
┌──────────────────────────────────────────────────────────────┐
│  Kubernetes Cluster Node(s)                                  │
│                                                              │
│  env-cluster.sh targets here (via kubectl from workstation): │
│    • Namespace                                               │
│    • Rancher Project                                         │
│    • Istio Gateway                                           │
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

## Step-by-Step Guide

### Step 1: Create DNS records

At your DNS provider, create two A records pointing to the **Nginx node's public IP**:

| Type | Name | Value |
|------|------|-------|
| A | `qa.openg2p.org` | `<nginx_node_ip>` |
| A | `*.qa.openg2p.org` | `<nginx_node_ip>` |

Verify propagation before proceeding:

```bash
dig qa.openg2p.org
# Should return the Nginx node IP
```

### Step 2: Obtain Let's Encrypt wildcard certificate (on Nginx node)

SSH into the Nginx node and run certbot with DNS-01 challenge:

```bash
sudo certbot certonly \
  --manual \
  --preferred-challenges dns \
  --agree-tos \
  --email admin@openg2p.org \
  -d "qa.openg2p.org" \
  -d "*.qa.openg2p.org"
```

Certbot will prompt you to create a DNS TXT record:

```
Please deploy a DNS TXT record under the name:
  _acme-challenge.qa.openg2p.org
with the following value:
  <random_string>
```

**Do this:**
1. Go to your DNS provider
2. Create a TXT record: `_acme-challenge.qa.openg2p.org` → `<random_string>`
3. Wait for propagation (verify with `dig TXT _acme-challenge.qa.openg2p.org`)
4. Press Enter in the certbot prompt

Certbot may ask for **two** TXT records (one for each domain). Create both before pressing Enter.

On success, certs will be at:
```
/etc/letsencrypt/live/qa.openg2p.org/fullchain.pem
/etc/letsencrypt/live/qa.openg2p.org/privkey.pem
```

> **Automated DNS plugins:** If you use Cloudflare or Route53, you can automate the TXT record step:
> ```bash
> # Cloudflare (needs /etc/letsencrypt/cloudflare.ini with API token)
> sudo certbot certonly --dns-cloudflare \
>   --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
>   --dns-cloudflare-propagation-seconds 30 \
>   -d "qa.openg2p.org" -d "*.qa.openg2p.org"
>
> # Route53 (needs AWS credentials in environment)
> sudo certbot certonly --dns-route53 \
>   --dns-route53-propagation-seconds 30 \
>   -d "qa.openg2p.org" -d "*.qa.openg2p.org"
> ```

### Step 3: Create Nginx server block (on Nginx node)

Create the server block file:

```bash
sudo tee /etc/nginx/sites-available/openg2p-env-qa.conf > /dev/null <<'EOF'
# OpenG2P environment: qa
# Domain: *.qa.openg2p.org

server {
    listen 80;
    server_name *.qa.openg2p.org qa.openg2p.org;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name *.qa.openg2p.org qa.openg2p.org;

    ssl_certificate     /etc/letsencrypt/live/qa.openg2p.org/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/qa.openg2p.org/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;

    location / {
        proxy_pass                      http://istio_ingress;
        proxy_http_version              1.1;
        proxy_buffering                 on;
        proxy_buffers                   8 16k;
        proxy_buffer_size               16k;
        proxy_busy_buffers_size         32k;
        proxy_set_header                Upgrade $http_upgrade;
        proxy_set_header                Connection "upgrade";
        proxy_set_header                Host $host;
        proxy_set_header                X-Real-IP $remote_addr;
        proxy_set_header                X-Forwarded-Host $host;
        proxy_set_header                X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header                X-Forwarded-Proto https;
        proxy_pass_request_headers      on;
    }
}
EOF
```

> **Note:** The `istio_ingress` upstream must already exist in your Nginx config
> (typically in `/etc/nginx/conf.d/upstream.conf` or similar). It should point to the
> cluster node's Istio ingress gateway port. Example:
> ```nginx
> upstream istio_ingress {
>     server <cluster_node_ip>:30080;
> }
> ```

Enable and reload:

```bash
sudo ln -sf /etc/nginx/sites-available/openg2p-env-qa.conf \
            /etc/nginx/sites-enabled/openg2p-env-qa.conf
sudo nginx -t && sudo systemctl reload nginx
```

### Step 4: Prepare env-cluster.sh config (on your workstation)

```bash
cp env-config.example.yaml env-config.yaml
```

Edit `env-config.yaml`:

```yaml
environment: "qa"
base_domain: "qa.openg2p.org"
keycloak_hostname: "keycloak.openg2p.org"

keycloak:
  client_manager_user: "client-manager@openg2p.org"
  client_manager_password: "your-password-here"
```

### Step 5: Run env-cluster.sh (from your workstation)

```bash
./env-cluster.sh --config env-config.yaml
```

This will:
1. Create the K8s namespace
2. Create a Rancher Project and associate the namespace
3. Create the Istio Gateway for `*.qa.openg2p.org`
4. Create the Keycloak client-manager secret
5. Install `openg2p-commons-base` (PostgreSQL, Kafka, MinIO, Redis, etc.)
6. Install `openg2p-commons-services` (eSignet, Superset, ODK, etc.)

## File Structure

```
environment/
├── env-cluster.sh            # Run from workstation (kubectl/helm)
├── env-config.example.yaml   # Example config — copy and edit
├── lib/
│   └── utils.sh              # Shared utilities (logging, config parser)
└── .gitignore                # Ignores env-config.yaml
```

## Configuration Reference

| Key | Description |
|-----|-------------|
| `environment` | Environment name — used as namespace and Rancher project (e.g., `qa`) |
| `base_domain` | Full base domain for this environment (e.g., `qa.openg2p.org`) |
| `keycloak_hostname` | Keycloak hostname from infra setup (e.g., `keycloak.openg2p.org`) |
| `keycloak.client_manager_user` | Keycloak client-manager username |
| `keycloak.client_manager_password` | Keycloak client-manager password |
| `commons_base.chart_version` | Helm chart version for openg2p-commons-base |
| `commons_base.chart_path` | Local chart path (leave empty to use remote repo) |
| `commons_base.extra_helm_args` | Additional `--set` flags for the base chart |
| `commons_services.chart_version` | Helm chart version for openg2p-commons-services |
| `commons_services.chart_path` | Local chart path (leave empty to use remote repo) |
| `commons_services.extra_helm_args` | Additional `--set` flags for the services chart |
| `modules.commons` | Enable/disable commons installation (`true`/`false`) |

## CLI Options

```
./env-cluster.sh --config env-config.yaml [options]

Options:
  --config <file>    Path to environment config file (required)
  --step <N>         Run only a specific step (1-6)
  --force            Uninstall and reinstall Helm charts
  --help             Show this help message

Steps:
  1  Create K8s namespace
  2  Create Rancher Project
  3  Create Istio Gateway
  4  Create Keycloak client-manager secret
  5  Install openg2p-commons-base
  6  Install openg2p-commons-services
```

## Creating Multiple Environments

To create additional environments (e.g., `staging`) on the same cluster:

1. Create DNS records for `staging.openg2p.org` and `*.staging.openg2p.org` → Nginx IP
2. On Nginx node: obtain cert and create server block (repeat Steps 2-3 with the new domain)
3. Create a new config file with `environment: staging` and `base_domain: staging.openg2p.org`
4. Run `env-cluster.sh` from your workstation with the new config

Each environment gets its own namespace, Rancher project, Istio gateway, and full set of services.

## Idempotency

`env-cluster.sh` is safe to re-run. It checks for existing namespace, project, gateway, secret, and Helm releases before creating them. Use `--force` to tear down and reinstall Helm charts.

## Troubleshooting

### Certificate issues (on Nginx node)

```bash
# Check if cert exists
sudo ls -la /etc/letsencrypt/live/qa.openg2p.org/

# Test renewal
sudo certbot renew --dry-run

# Check TXT record propagation
dig TXT _acme-challenge.qa.openg2p.org
```

### Nginx issues (on Nginx node)

```bash
# Test config syntax
sudo nginx -t

# Check the server block
cat /etc/nginx/sites-enabled/openg2p-env-qa.conf

# Check if upstream exists
grep -r "istio_ingress" /etc/nginx/

# Check Nginx error log
sudo tail -50 /var/log/nginx/error.log
```

### Cluster issues (from workstation)

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
kubectl get projects.management.cattle.io -n local -o json | \
  jq '.items[] | {name: .metadata.name, display: .spec.displayName}'
```
