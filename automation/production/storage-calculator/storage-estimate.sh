#!/usr/bin/env bash
# =============================================================================
# storage-estimate.sh — per-node disk usage of the OpenG2P production
# infrastructure BEFORE Commons is installed.
#
#   ./storage-estimate.sh                              # print the model
#   sudo ./storage-estimate.sh --measure --role compute        # measure a live node
#   sudo ./storage-estimate.sh --measure --role storage
#   sudo ./storage-estimate.sh --measure --role reverse-proxy
#
# See README.md for the component breakdown and assumptions.
# =============================================================================
set -euo pipefail

MODE="estimate"
ROLE=""

usage() {
    cat <<'EOF'
Usage:
  storage-estimate.sh                          Print the modeled estimate (per node).
  storage-estimate.sh --measure --role ROLE    Measure actual usage on a live node.

  ROLE = compute | storage | reverse-proxy | backup

Run --measure with sudo (du needs to read /var/lib/rancher, /var/lib/postgresql, …).
Measure AFTER infrastructure is up but BEFORE the environment stage (Commons).
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --measure)  MODE="measure"; shift ;;
        --estimate) MODE="estimate"; shift ;;
        --role)     ROLE="${2:-}"; shift 2 ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

# Typical-column totals (GB), kept in sync with README.md.
declare -A TYP=( [reverse-proxy]=3.8 [compute]=12.0 [storage]=4.5 [backup]=3.9 )

# ─────────────────────────────────────────────────────────────────────────
# Estimate mode — print the model
# ─────────────────────────────────────────────────────────────────────────
print_estimate() {
    cat <<'EOF'
OpenG2P production — disk per node, BEFORE Commons
(base OS + packages + RKE2 + Rancher/Istio/monitoring/logging; empty PostgreSQL)

=== B. PROVISIONING BUDGET — what to allocate (use THIS for sizing/future) ===

  Node                 OS budget   + Platform/growth        = Root budget   Procured
  ─────────────────────────────────────────────────────────────────────────────────
  Reverse Proxy          25 GB     ~5 GB  (nginx/WG/logs)      ~30 GB        64 GB
  Compute (K8s)          25 GB     ~30-40 GB (RKE2+images)     ~55-65 GB    128 GB
  Storage (PG + NFS)     25 GB     data sized by Commons       ~25 GB root  256 GB  + PG/NFS data
  Backup                 25 GB     ~5 GB                       ~30 GB root   64 GB  + repo on >=1TB vol
  ─────────────────────────────────────────────────────────────────────────────────
  OS budget, all 4 nodes = 100 GB

  Ubuntu is on ALL FOUR nodes -> 25 GB OS budget each. This is NOT day-1 usage
  (~3-5 GB) — it's headroom for YEARS of apt updates, kernels, logs, apt cache,
  snaps, /tmp. Size disks once, for the life of the system.

=== A. USED RIGHT NOW (pre-Commons) — reality check, NOT a sizing number ===

  Node                 Low      Typical    High     Notes
  ───────────────────────────────────────────────────────────────────────────
  Reverse Proxy        2.6 GB    3.8 GB    5.9 GB    Ubuntu + nginx + WG
  Compute (K8s)        8.3 GB   12.0 GB   17.6 GB    dominated by image store
  Storage (PG + NFS)   2.9 GB    4.5 GB    7.5 GB    empty PG + infra PVCs
  Backup (separate)    2.6 GB    3.9 GB    6.0 GB    root disk; repo empty

  Note: `apt-get update` refreshes the index only (~100-200 MB); it installs no
  libraries. An "8-10 GB base Ubuntu" figure = Desktop, or RKE2/image store
  counted as OS.

Key points:
  • Day 1 uses only ~4-12 GB/node; the 25 GB OS budget + platform/data headroom
    is what you provision. Sizing is driven by application data AFTER Commons +
    observability retention, not the day-1 platform.
  • Compute = container image store (RKE2 system images + Rancher + monitoring
    + Istio + Loki/MinIO + OTel). Its persistent DATA is tiny — the observability
    PVCs are nfs-csi-backed and live on the STORAGE node.
  • Storage = empty PostgreSQL cluster + the infra observability PVCs (Prometheus,
    Loki, Loki-MinIO, Grafana, Alertmanager). Near-empty now; grows with retention.

Logs — 7-day retention window (loki_retention_hours=168, enforced by compactor):
  • Infra-only log accumulation in Loki's MinIO store (on the STORAGE node):
        ~0.4 GB (low)   ~1.8 GB (typical)   ~7 GB (high)
    from ~0.5 / 2 / 5 GB/day raw × 7 days, compressed ~5-10x. Well within the
    50Gi MinIO PVC. Raw container logs on COMPUTE are capped (50MiB x5/container),
    not a 7-day accumulation. Commons adds app-log streams on top of this.

Validate on a live node:  sudo ./storage-estimate.sh --measure --role compute
Full breakdown + assumptions: see README.md
EOF
}

# ─────────────────────────────────────────────────────────────────────────
# Measure mode — du the role's key paths on a live node
# ─────────────────────────────────────────────────────────────────────────
du_path() {
    local label="$1" path="$2"
    if [[ -e "$path" ]]; then
        local size
        size=$(du -sh "$path" 2>/dev/null | awk '{print $1}')
        printf "  %-46s %8s   %s\n" "$label" "${size:-?}" "$path"
    else
        printf "  %-46s %8s   %s\n" "$label" "—" "$path (absent)"
    fi
}

measure_role() {
    local role="$1"
    [[ $EUID -eq 0 ]] || echo "  (tip: run with sudo for accurate du on system paths)"
    echo "Measured disk usage — role: ${role}"
    echo "  ──────────────────────────────────────────────────────────────────────"
    case "$role" in
        compute)
            du_path "RKE2 root (binaries+images+etcd+logs)" "/var/lib/rancher"
            du_path "  └ containerd image store"            "/var/lib/rancher/rke2/agent/containerd"
            du_path "  └ etcd database"                     "/var/lib/rancher/rke2/server/db"
            du_path "CLI tools (kubectl/helm/istioctl/…)"   "/usr/local/bin"
            du_path "System logs"                           "/var/log"
            ;;
        storage)
            du_path "PostgreSQL data"                       "/var/lib/postgresql"
            du_path "NFS export (infra PVCs)"               "/srv/nfs"
            du_path "System logs"                           "/var/log"
            # Per-PVC breakdown — shows which observability volume (Loki/MinIO,
            # Prometheus, Grafana) is consuming the 7-day log/metric retention.
            if [[ -d /srv/nfs ]]; then
                echo "  ── largest NFS PVC directories (Loki/MinIO = 7-day logs) ──"
                du -h -d 3 /srv/nfs 2>/dev/null | sort -rh | head -8 | sed 's/^/    /' || true
            fi
            ;;
        reverse-proxy)
            du_path "nginx config"                          "/etc/nginx"
            du_path "Wireguard config"                      "/etc/wireguard"
            du_path "OpenG2P certs/secrets"                 "/etc/openg2p"
            du_path "nginx + system logs"                   "/var/log"
            ;;
        backup)
            du_path "Backup tooling configs"                "/etc/openg2p-backup"
            du_path "Backup repository (data volume)"       "/var/lib/openg2p-backup"
            du_path "System logs"                           "/var/log"
            ;;
        *) echo "Unknown role: ${role}" >&2; usage; exit 1 ;;
    esac
    echo "  ── OS base / overhead (the '~3-5 GB base', common to all roles) ──"
    du_path "apt .deb cache"             "/var/cache/apt/archives"
    du_path "kernels / kernel modules"   "/usr/lib/modules"
    du_path "boot (kernels, initramfs)"  "/boot"
    du_path "snaps"                      "/var/lib/snapd"
    echo "  ──────────────────────────────────────────────────────────────────────"
    echo "Root filesystem:"
    df -h / | sed 's/^/  /'
    echo ""
    echo "Model estimate (typical) for ${role}: ${TYP[$role]:-?} GB on /."
    echo "Compare the 'Used' column above. Measure BEFORE installing Commons."
}

# ─────────────────────────────────────────────────────────────────────────
if [[ "$MODE" == "measure" ]]; then
    [[ -n "$ROLE" ]] || { echo "--measure requires --role" >&2; usage; exit 1; }
    measure_role "$ROLE"
else
    print_estimate
fi
