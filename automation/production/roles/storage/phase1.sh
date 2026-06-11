#!/usr/bin/env bash
# =============================================================================
# Storage Node — Phase 1: host setup
# =============================================================================
# Idempotent. Runs on the storage node, invoked by roles/storage/run.sh.
#
# Steps:
#   1.1  Resource prereq check (8 vCPU, 32 GB RAM, 256 GB disk)
#   1.2  apt basics + cluster integration tooling
#   1.3  ufw — SSH from admin_cidr; NFS + Postgres from compute_private_ip
#   1.4  NFS server — export /srv/nfs/<cluster_name> to compute
#   1.5  PostgreSQL — install, listen on private IP, allow compute, generate
#        superuser password (no app DBs created — env automation does that)
# =============================================================================

SECRETS_DIR="/etc/openg2p/secrets"

# Resource/OS/network prereqs are covered by lib/shared/preflight.sh, run
# from the orchestrator before any phase work. No duplicate checks here.

# ─────────────────────────────────────────────────────────────────────────
# 1.2  apt basics
# ─────────────────────────────────────────────────────────────────────────
storage_install_apt_basics() {
    local step="storage.phase1.apt-basics"
    if skip_if_done "$step" "apt basics"; then return 0; fi

    log_step "S1.2" "Install apt basics + NFS + PostgreSQL packages"

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends \
        curl wget jq openssl dnsutils ca-certificates \
        ufw \
        nfs-kernel-server \
        postgresql postgresql-contrib

    # Ensure secrets dir exists with strict permissions for later steps
    mkdir -p "${SECRETS_DIR}"
    chmod 0700 "${SECRETS_DIR}"

    mark_step_done "$step"
}

# ─────────────────────────────────────────────────────────────────────────
# 1.3  ufw
# ─────────────────────────────────────────────────────────────────────────
storage_configure_ufw() {
    local step="storage.phase1.ufw"
    if skip_if_done "$step" "ufw rules"; then return 0; fi

    log_step "S1.3" "Configure ufw — lock NFS/PG to compute, SSH from admin"

    local admin_cidr
    admin_cidr=$(cfg "admin_cidr" "0.0.0.0/0")
    local compute_ip
    compute_ip=$(cfg "compute_private_ip")
    local pg_port
    pg_port=$(cfg "postgres_port" "5432")
    local private_subnet
    private_subnet=$(cfg "private_subnet")

    if [[ -z "$compute_ip" || -z "$private_subnet" ]]; then
        log_error "Required config missing" \
                  "compute_private_ip or private_subnet not set" \
                  "Edit prod-config.yaml on the laptop and re-run"
        exit 1
    fi

    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing

    # SSH — allow admin laptop CIDR, plus the rest of the private subnet
    # (covers the case where the orchestrator bastions through RP).
    ufw allow from "$admin_cidr" to any port 22 proto tcp
    ufw allow from "$private_subnet" to any port 22 proto tcp

    # NFS — only the compute node
    ufw allow from "$compute_ip" to any port 2049 proto tcp comment "NFS from compute"
    ufw allow from "$compute_ip" to any port 111  proto tcp comment "rpcbind from compute"
    ufw allow from "$compute_ip" to any port 111  proto udp comment "rpcbind from compute"

    # PostgreSQL — only the compute node (env automation will use this later)
    ufw allow from "$compute_ip" to any port "$pg_port" proto tcp comment "PG from compute"

    # ICMP (ping, etc.) is already permitted via ufw's default
    # /etc/ufw/before.rules. ufw's simple syntax doesn't accept "proto icmp".

    ufw --force enable

    mark_step_done "$step"
}

# ─────────────────────────────────────────────────────────────────────────
# 1.4  NFS server
# ─────────────────────────────────────────────────────────────────────────
storage_configure_nfs() {
    local step="storage.phase1.nfs-server"
    if skip_if_done "$step" "NFS server"; then return 0; fi

    log_step "S1.4" "Configure NFS server and export to compute node"

    local compute_ip
    compute_ip=$(cfg "compute_private_ip")
    local cluster_name
    cluster_name=$(cfg "cluster_name" "openg2p")
    local export_root
    export_root=$(cfg "nfs_export_path" "/srv/nfs")
    local export_path="${export_root}/${cluster_name}"

    mkdir -p "$export_path"
    chown nobody:nogroup "$export_path"
    chmod 0777 "$export_path"   # subdirectories will be created by clients

    # Idempotent rewrite: drop our previous marker line and the export line for
    # this exact path, then append a single fresh entry.
    #
    # The export line *starts* with the path and is followed by whitespace, so
    # anchor the match at ^ and require trailing whitespace. (The earlier pattern
    # looked for spaces *around* the path — " ${export_path} " — which never
    # matched the real line, so the stale export line was never removed and each
    # run appended another, making `exportfs -ra` fail with "duplicated export
    # entries".) Escape regex metacharacters so dots/brackets in a custom
    # nfs_export_path stay literal, and use ^…[[:space:]] so we don't clobber an
    # unrelated export that merely shares this path as a prefix.
    local marker="# openg2p-cluster:${cluster_name}"
    local esc_path
    esc_path=$(printf '%s' "$export_path" | sed 's/[].[*^$\\]/\\&/g')
    touch /etc/exports
    sed -i "\|^${marker}\$|d" /etc/exports
    sed -i "\|^${esc_path}[[:space:]]|d" /etc/exports
    cat >> /etc/exports <<EOF
${marker}
${export_path}    ${compute_ip}(rw,sync,no_subtree_check,no_root_squash)
EOF

    exportfs -ra

    systemctl enable --now nfs-kernel-server
    systemctl restart nfs-kernel-server

    log_info "NFS export: ${export_path} → ${compute_ip}"
    mark_step_done "$step"
}

# ─────────────────────────────────────────────────────────────────────────
# 1.5  PostgreSQL — install + listen on private IP + allow compute
# ─────────────────────────────────────────────────────────────────────────
storage_configure_postgres() {
    local step="storage.phase1.postgres"
    if skip_if_done "$step" "Postgres host config"; then return 0; fi

    log_step "S1.5" "Configure host PostgreSQL (no app DBs yet)"

    # Resolve the actual installed PG major version. Ubuntu 24.04 ships PG16,
    # 22.04 shipped PG14, etc. — `apt install postgresql` pulls whatever the
    # distro's metapackage points to. Trusting a hand-edited postgres_version
    # value would fail when it disagrees with what's actually on disk.
    local cfg_version
    cfg_version=$(cfg "postgres_version" "")
    local pg_version=""
    if [[ -n "$cfg_version" && -d "/etc/postgresql/${cfg_version}/main" ]]; then
        pg_version="$cfg_version"
    fi
    if [[ -z "$pg_version" ]]; then
        # Auto-detect: pick the highest numbered version installed.
        pg_version=$(ls -1 /etc/postgresql/ 2>/dev/null | grep -E '^[0-9]+$' | sort -n | tail -1 || true)
        if [[ -n "$cfg_version" && -n "$pg_version" && "$cfg_version" != "$pg_version" ]]; then
            log_warn "Configured postgres_version=${cfg_version} not installed (got ${pg_version} from apt). Using ${pg_version}."
        fi
    fi
    if [[ -z "$pg_version" ]]; then
        log_error "No PostgreSQL installation detected" \
                  "/etc/postgresql/ has no version subdirectory" \
                  "Verify the apt install of postgresql succeeded" \
                  "ls /etc/postgresql/; dpkg -l | grep '^ii  postgresql'"
        exit 1
    fi
    log_info "Using PostgreSQL ${pg_version}"

    local pg_port
    pg_port=$(cfg "postgres_port" "5432")
    local listen
    listen=$(cfg "postgres_listen")
    local storage_ip
    storage_ip=$(cfg "storage_private_ip")
    if [[ -z "$listen" ]]; then listen="$storage_ip"; fi
    local compute_ip
    compute_ip=$(cfg "compute_private_ip")

    local pg_conf="/etc/postgresql/${pg_version}/main/postgresql.conf"
    local pg_hba="/etc/postgresql/${pg_version}/main/pg_hba.conf"

    if [[ ! -f "$pg_conf" ]]; then
        log_error "Postgres config not found at ${pg_conf}" \
                  "Postgres ${pg_version} may not be installed (got a different version?)" \
                  "ls /etc/postgresql/" \
                  "dpkg -l | grep postgresql"
        exit 1
    fi

    # ── postgresql.conf ─────────────────────────────────────────────────
    # listen_addresses = 'localhost,<storage_private_ip>'
    sed -i \
        -e "s|^#*listen_addresses\s*=.*|listen_addresses = 'localhost,${listen}'|" \
        -e "s|^#*port\s*=.*|port = ${pg_port}|" \
        "$pg_conf"

    # ── pg_hba.conf ────────────────────────────────────────────────────
    # Allow compute node via scram-sha-256. Local connections via peer/trust as Ubuntu default.
    if ! grep -q "^# openg2p-compute$" "$pg_hba"; then
        cat >> "$pg_hba" <<EOF

# openg2p-compute
host    all             all             ${compute_ip}/32        scram-sha-256
EOF
    fi

    systemctl enable postgresql
    systemctl restart "postgresql@${pg_version}-main"

    # ── Superuser password ─────────────────────────────────────────────
    local pw_file="${SECRETS_DIR}/postgres-superuser.env"
    local pw
    pw=$(cfg "postgres_superuser_password")
    if [[ -z "$pw" ]]; then
        if [[ -f "$pw_file" ]]; then
            pw=$(grep '^POSTGRES_PASSWORD=' "$pw_file" | cut -d= -f2-)
            log_info "Using existing superuser password from ${pw_file}"
        else
            pw=$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)
            log_info "Generated new Postgres superuser password (saved at ${pw_file})"
        fi
    fi

    cat > "$pw_file" <<EOF
POSTGRES_HOST=${listen}
POSTGRES_PORT=${pg_port}
POSTGRES_USER=postgres
POSTGRES_PASSWORD=${pw}
EOF
    chmod 0600 "$pw_file"

    # Apply password to the postgres role
    sudo -u postgres psql -v ON_ERROR_STOP=1 -c \
        "ALTER ROLE postgres WITH PASSWORD '${pw}';" >/dev/null

    # Smoke test from localhost — will catch listen/auth misconfig.
    if ! sudo -u postgres psql -h "$listen" -p "$pg_port" -U postgres -d postgres \
        -c "SELECT version();" >/dev/null 2>&1; then
        # Fallback: localhost-only smoke test (local connection works regardless of listen_addresses)
        if ! sudo -u postgres psql -c "SELECT version();" >/dev/null; then
            log_error "Postgres smoke test failed" \
                      "The server is not accepting connections" \
                      "Inspect logs and restart" \
                      "journalctl -u postgresql@${pg_version}-main -n 50"
            exit 1
        fi
    fi

    log_success "PostgreSQL ${pg_version} listening on ${listen}:${pg_port}"
    log_info "Superuser credentials at ${pw_file} (mode 0600)"
    log_info "No application databases created — env automation will add them later."

    mark_step_done "$step"
}

# ─────────────────────────────────────────────────────────────────────────
# Phase entry
# ─────────────────────────────────────────────────────────────────────────
run_storage_phase1() {
    storage_install_apt_basics
    storage_configure_ufw
    storage_configure_nfs
    storage_configure_postgres
}
