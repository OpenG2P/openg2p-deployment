# Storage Estimator — production infrastructure, **before Commons**

This estimates the disk consumed **per node** for a fresh three-node production
install, in **two layers**:

1. **Infra baseline** — Ubuntu + packages + the RKE2 cluster with all the infra
   deployments/statefulsets (Rancher, Istio, monitoring, logging), **before**
   Commons and before any application data.
2. **+ Commons layer** — `openg2p-commons-base` + `openg2p-commons-services`
   installed and running for **~7 days of logs**, with **light / no application
   data** (no large beneficiary datasets or traffic yet). See
   [Commons layer](#commons-layer--laid-on-top-of-the-infra-baseline).

> **Scope.** Layer 1 is the "Stage 3 done, Stage 4 not started" snapshot (empty
> host PostgreSQL). Layer 2 is "Stage 4 done + idling a week." Neither models
> **production-scale application data** (beneficiaries, transactions, documents)
> — that is usage-driven and sized separately.

Run `./storage-estimate.sh` to print the model below, or
`./storage-estimate.sh --measure --role <compute|storage|reverse-proxy>` **on a
live node** to compare the model against real `du`/`df` numbers.

---

## Bottom line

This answers **two different questions**. For **sizing / procurement, use the
budget (B)** — it's the forward-looking number. (A) is only a day-1 reality
check.

### B. Provisioning budget — what to allocate per node (forward-looking) ⭐

Every node runs **Ubuntu**, so every node carries a **25 GB OS budget**. This is
not day-1 usage (~3–5 GB) — it is what you **allocate for the life of the
system**: the OS plus *years* of apt updates, accumulating kernels,
journald/log growth, apt cache, snaps, `/tmp`, and headroom. Size the disk once.

| Node | **OS budget** | + Platform / growth headroom | **= Root-disk budget** | Separate data volume | Procured |
|------|--------------:|------------------------------|-----------------------:|----------------------|---------:|
| **Reverse Proxy** | 25 GB | ~5 GB (nginx, WG, certs, logs) | **~30 GB** | — | 64 GB |
| **Compute** (K8s) | 25 GB | ~30–40 GB (RKE2 + image store + churn + logs) | **~55–65 GB** | — | 128 GB |
| **Storage** (PG + NFS) | 25 GB | (data dominates — sized by Commons) | **~25 GB root** | + PostgreSQL + NFS data | 256 GB |
| **Backup** | 25 GB | ~5 GB | **~30 GB root** | + repo on ≥1 TB volume | 64 GB + ≥1 TB |
| **OS budget across all 4 nodes** | **100 GB** | | | | |

> **OS = 25 GB on every node** (Ubuntu is on all four — RP, Compute, Storage,
> Backup). The Storage and Backup nodes also carry their **data** on the same or
> a separate volume (PostgreSQL + NFS observability/app data; the backup repo) —
> that data, not the OS, is what drives their large procured disks and is sized
> by the **Commons / module** footprint, estimated separately.

### A. Used right now (pre-Commons) — reality check, **not** a sizing number

| Node | Low | **Typical used** | High |
|------|----:|-----------------:|-----:|
| Reverse Proxy | 2.6 GB | **3.8 GB** | 5.9 GB |
| Compute (K8s) | 8.3 GB | **12.0 GB** | 17.6 GB |
| Storage (PG + NFS) | 2.9 GB | **4.5 GB** | 7.5 GB |
| Backup (separate) | 2.6 GB | **3.9 GB** | 6.0 GB |

These are what `df` shows on day 1; the [per-node breakdown](#per-node-breakdown)
details every line. The gap between (A) ~4–12 GB used and (B) 25 GB+ budgeted is
**intentional** — you provision for the future, not for day 1.

**Why the budget matters here**

- **Compute** is dominated by the **container image store** (RKE2 system images +
  Rancher + monitoring + Istio + Loki/MinIO + OTel) — and that store *churns and
  grows* with upgrades, so it needs headroom well beyond day-1 usage.
- **Storage** holds the infra **observability PVCs** (Prometheus, Loki, Loki's
  MinIO, Grafana, Alertmanager) plus the empty PostgreSQL cluster today; its big
  disk is for **post-Commons application data**.
- **OS growth is real and easy to forget** — kernels, logs, and apt cache
  accumulate on *every* node, which is exactly why the 25 GB OS budget exists.

---

## Commons layer — laid on top of the infra baseline

This is the **infra baseline + Commons installed + ~7 days of logs**, with
**light / no application data** (no large beneficiary datasets, no traffic
load yet). Commons = `openg2p-commons-base` + `openg2p-commons-services`. It
touches **Compute** (container images + ephemeral volumes) and **Storage**
(PostgreSQL databases + NFS PVCs + more logs). It does **not** touch the Reverse
Proxy. In-cluster PostgreSQL is **disabled** (host PG on Storage), so there is no
in-cluster PG PVC.

### Where each Commons piece lands

| Commons component | Image → **Compute** | DB → **Storage / host PG** | Persistent vol | Notes |
|---|---|---|---|---|
| keycloak (+ keycloak-init job) | ~0.6 + 0.3 GB | `keycloak` | — (DB-backed) | |
| postgres-init (job) | ~0.3 GB | creates the 9 DBs | — | |
| minio | ~0.3 GB | — | **16 Gi PVC → NFS** | the one big provisioned PVC; fills with keys/objects |
| kafka | ~0.7 GB | — | **emptyDir → Compute** | `persistence.enabled: false` — ephemeral, *not* NFS |
| kafka-ui | ~0.35 GB | — | — | |
| redis + redis-auth (×2) | ~0.15 GB (shared image) | — | **emptyDir → Compute** | both `persistence: false` |
| softhsm | ~0.3 GB | — | small PVC → NFS | HSM key store (a few MB used) |
| mail | ~0.15 GB | — | — | |
| master-data | ~0.5 GB | `master_data` | — | |
| keymanager | ~0.6 GB | `mosip_keymgr` | — | uses softhsm |
| superset | ~1.2 GB | `superset` | — | uses redis |
| esignet | ~0.6 GB | `mosip_esignet` | — | embeds keymanager |
| mock-identity-system | ~0.5 GB | `mosip_mockidentitysystem` | — | |
| odk-central (multi-container) | ~1.5 GB | `odkdb` | small enketo vol | nginx + service + enketo + pyxform |
| iam-service (+ staff-portal-api) | ~0.8 GB | `iam` | — | |
| audit-manager | ~0.5 GB | `audit_manager` | — | |
| staff-portal-ui | ~0.1 GB | — | — | static nginx |
| artifactory | ~0.1 GB | — | — | small nginx (despite the name) |

### Commons increment — Compute node

| Item | Low | Typ | High |
|------|----:|----:|-----:|
| **Container images** (the ~19 components above; shared base layers discounted, containerd extraction added) | 6.0 | 9.0 | 14.0 |
| **emptyDir ephemeral** — Kafka + Redis×2 (`persistence: false`), on the Compute root disk; grows with topic/cache data | 0.1 | 0.5 | 1.5 |
| Extra container logs (capped 50 MiB × 5 per container × ~20 new containers) | 0.2 | 0.5 | 1.0 |
| **Compute Commons increment** | **6.3** | **10.0** | **16.5** |

> **Docker on disk is the dominant Commons cost on Compute (~6–14 GB).** It
> roughly *doubles* the image store vs infra-only. Image-size rows are
> **category estimates** — validate with `crictl images` /
> `--measure --role compute` after install (the biggest line is Superset + ODK +
> the Java services).

### Commons increment — Storage node

| Item | Low | Typ | High |
|------|----:|----:|-----:|
| **PostgreSQL inflation** — 9 commons DBs: schema/migrations + ~7 days of light operation (sessions, audit) | 0.2 | 0.5 | 1.5 |
| **NFS inflation** — MinIO objects (16 Gi PVC, fills with eSignet keys / ODK submissions / certs), SoftHSM, ODK enketo. *Actual* data at install is small; the **16 Gi is provisioned-nominal** | 0.3 | 1.0 | 4.0 |
| **7-day log store growth** — ~20 Commons pods added to Loki/MinIO (see below) | 1.0 | 2.5 | 4.0 |
| **Storage Commons increment** | **1.5** | **4.0** | **9.5** |

> **PostgreSQL and NFS *software* were already in the 25 GB OS budget** — this
> increment is the **data** they now hold. At install it's small; it grows with
> real usage (beneficiaries, transactions, documents, keys), which is
> **usage-driven and sized separately** from this "installed + idle" snapshot.

### 7-day logs, per Commons component (the log layer grows)

Adding ~20 Commons pods raises the daily log volume. Rough **idle** per-component
rates (raw, no traffic):

| Component group | Raw/day (each) |
|---|---|
| Java/Spring services (keymanager, esignet, mock-identity, master-data, iam, audit) | ~0.1–0.3 GB |
| Superset, ODK-central | ~0.1–0.2 GB |
| Keycloak, Kafka | ~0.05–0.2 GB |
| MinIO, Redis×2, SoftHSM, mail, UIs, init jobs | ~0.02–0.1 GB |

| | Low | Typical | High |
|---|----:|--------:|-----:|
| Commons daily raw logs (sum of the above) | ~1 GB/day | ~2 GB/day | ~3 GB/day |
| × 7 days, ÷ ~8 compression | ~0.9 GB | ~1.8 GB | ~2.6 GB |
| **+ infra logs (already counted)** | +0.4 | +1.8 | +7.0 |
| **= total 7-day Loki/MinIO store (Storage)** | **~1.3 GB** | **~3.6 GB** | **~9.6 GB** |

Still inside the 50 Gi Loki-MinIO PVC. Once **citizen traffic** flows (post-go-
live), per-request logs (eSignet, Keycloak, Istio access logs if enabled)
dominate — size for that separately.

### Combined: infra **+** Commons (installed + 7-day logs, light app data)

| Node | Used (Low) | **Used (Typical)** | Used (High) | Budget (root) | Procured |
|------|-----------:|-------------------:|------------:|--------------:|---------:|
| Reverse Proxy | 2.6 | **3.8 GB** | 5.9 | ~30 GB | 64 GB |
| Compute (K8s) | 14.6 | **22.0 GB** | 34.1 | **~60–70 GB** | 128 GB |
| Storage (PG + NFS) | 4.4 | **8.5 GB** | 17.0 | **25 GB + data** | 256 GB |
| **3-node total** | **21.6** | **~34.3 GB** | **57.0** | | |

- **Compute** budget rises to ~60–70 GB (OS 25 + infra images ~12 + Commons
  images ~10 + churn/ephemeral/log headroom). Still ~half of the 128 GB disk.
- **Storage** used is still small (~8.5 GB) at install, but its **budget is
  data-driven** — the 256 GB disk is for production PostgreSQL + MinIO + the
  observability retention, sized from the module/usage estimate (next exercise).

---

## Base OS — used today (~3–5 GB) vs **budget (25 GB)**

The OS is on **every node**, and "how big is Ubuntu" has two answers — make sure
you use the **budget** for planning:

| Question | Figure | Use it for |
|---|---|---|
| What does the OS **use on day 1**? | **~3–5 GB** | sanity-checking a fresh node |
| What should I **budget / provision** for the OS? | **25 GB per node** | **sizing disks (this is the forward-looking number)** |

The **25 GB OS budget** (per node, all four nodes) deliberately exceeds day-1
usage because over the system's life the OS grows: apt updates, **accumulating
kernels** (~300 MB each, several over years), **journald/log growth**, the
**`.deb` cache** (`/var/cache/apt/archives`, 0.3–1.5 GB if never `apt-get
clean`-ed), **snaps** (~0.3–0.8 GB), `/tmp`, and general headroom. You size the
partition once, for years of operation.

Day-1 "used" decomposes as:

| What's measured | Size | In the day-1 model |
|---|---|---|
| Ubuntu 24.04 **cloud image** rootfs, fresh boot | ~1.6–2.2 GB | rootfs row |
| + apt index, `.deb` cache, kernel(s), snaps, baseline logs | +0.8–2.5 GB | OS-overhead row |
| **= realistic running server base, day 1** | **~3–5 GB** | both rows |
| Ubuntu **Server ISO** (standard, non-minimal) | +1.5–2.5 GB | add if not a cloud image |
| Ubuntu **Desktop** (GUI) | ~8–10+ GB | **not used here** |

Notes:

- **`apt-get update` installs nothing** — it only refreshes the package index
  (`/var/lib/apt/lists`, ~100–200 MB). Libraries come only from explicit
  `apt install`, which the automation runs with **`--no-install-recommends`**.
- An **8–10 GB "base Ubuntu"** figure almost always means a **Desktop** install,
  or a node where the **RKE2 / container image store** (the ~12 GB Compute figure
  in this doc) was counted as part of the OS.
- **Don't size disks on day-1 "used."** Budget the OS at **25 GB/node**, then add
  the platform (Compute) and data (Storage/Backup) on top — see the
  **Provisioning budget** table at the top of this page.

---

## Per-node breakdown

All figures are **on-disk GB** (what `du`/`df` would report), not registry
"pull" sizes. Container-image rows already include containerd's extraction
overhead (compressed content blobs **and** uncompressed overlay snapshots).

### Reverse Proxy node

| Component | Low | Typ | High |
|-----------|----:|----:|-----:|
| Ubuntu 24.04 cloud rootfs (fresh) | 1.6 | 2.0 | 2.8 |
| OS overhead: apt index + `.deb` cache + extra kernel(s) + snaps + baseline logs | 0.8 | 1.5 | 2.5 |
| Packages: `nginx`, `wireguard-tools`, `ufw`, `curl/wget/jq/openssl/dnsutils/ca-certificates` | 0.10 | 0.20 | 0.30 |
| Runtime: customer TLS certs, nginx server blocks, WG config, logs | 0.05 | 0.10 | 0.30 |
| **Total** | **2.6** | **3.8** | **5.9** |

No containers, no Kubernetes. Grows only with nginx access/error logs.

### Storage node

| Component | Low | Typ | High |
|-----------|----:|----:|-----:|
| Ubuntu 24.04 cloud rootfs (fresh) | 1.6 | 2.0 | 2.8 |
| OS overhead (apt cache + kernels + snaps + logs) | 0.8 | 1.5 | 2.5 |
| Packages: `postgresql-16` + `postgresql-contrib`, `nfs-kernel-server`, utils | 0.25 | 0.40 | 0.60 |
| PostgreSQL initial cluster (`initdb`, **no app DBs**) | 0.04 | 0.05 | 0.08 |
| NFS export `/srv/nfs/<cluster>` — infra observability PVCs just after infra (Prometheus, Loki, Loki-MinIO, Grafana, Alertmanager) | 0.20 | 0.50 | 1.50 |
| **Total** | **2.9** | **4.5** | **7.5** |

> NFS PVC **provisioned** sizes (e.g. Loki's MinIO `loki_minio_size: 50Gi`) are
> **nominal** — NFS doesn't pre-allocate. Before Commons the PVCs hold minutes
> of telemetry; this row is the fastest-growing one post-go-live (Prometheus +
> Loki 7-day retention — see [Log accumulation](#log-accumulation-over-the-7-day-retention-window)).

### Compute node (Kubernetes)

| Component | Low | Typ | High |
|-----------|----:|----:|-----:|
| Ubuntu 24.04 cloud rootfs (fresh) | 1.6 | 2.0 | 2.8 |
| OS overhead (apt cache + kernels + snaps + logs) | 0.8 | 1.5 | 2.5 |
| CLI tools: `kubectl`, `helm 3.17.3`, `istioctl 1.24.1`, `helmfile 1.1.0`, helm-diff | 0.30 | 0.40 | 0.60 |
| RKE2 `v1.33.6+rke2r1` runtime + bundled system images (etcd, coredns, metrics-server, kube-proxy, pause, runtime) | 1.5 | 2.2 | 3.0 |
| etcd database (CRDs + objects from Rancher/monitoring/logging) | 0.05 | 0.10 | 0.20 |
| Images — **Rancher 2.12.3** (rancher, webhook, fleet, gitjob, shell) | 1.0 | 1.3 | 1.8 |
| Images — **Istio 1.24.1** (istiod, ingressgateway/proxyv2) | 0.4 | 0.5 | 0.8 |
| Images — **rancher-monitoring** (Prometheus, Grafana, Alertmanager, node-exporter, kube-state-metrics, prometheus-operator, config-reloader) | 1.4 | 1.8 | 2.4 |
| Images — **Loki** + dedicated **MinIO** + `mc` | 0.6 | 0.9 | 1.3 |
| Images — **OpenTelemetry collector** (gateway + agent) | 0.2 | 0.35 | 0.5 |
| Images — **NFS-CSI driver** + raw-chart/job misc (busybox, kubectl, mc) | 0.2 | 0.4 | 0.7 |
| Container + journald logs (capped at 50 MiB × 5 per container by RKE2 config) | 0.2 | 0.5 | 1.0 |
| **Total** | **8.3** | **12.0** | **17.6** |

> The single biggest line is the **image store** under
> `/var/lib/rancher/rke2/agent/containerd`. Almost all of Compute's growth after
> this point is logs and image churn, not data — application *data* is external
> (Storage node) or on NFS PVCs (Storage node).

### Backup node (separate — not part of the K8s infra)

| Component | Low | Typ | High |
|-----------|----:|----:|-----:|
| Ubuntu 24.04 cloud rootfs + OS overhead | 2.4 | 3.5 | 5.3 |
| Backup tooling: `pgbackrest`, `restic`, `nfs-common`, `jq`, `curl`, `etcd-client` | 0.20 | 0.35 | 0.50 |
| Backup repo on the ≥1 TB data volume (empty before first backup) | 0.00 | 0.05 | 0.20 |
| **Total (root disk)** | **2.6** | **3.9** | **6.0** |

The backup repository lives on the separate data volume and is empty until the
first backup runs (after Commons + go-live). Listed for completeness.

---

## Log accumulation over the 7-day retention window

**Confirmed: yes, the assumption is 7 days.** `loki_retention_hours: "168"`
(168 h = 7 days) flows from `prod-config.yaml` → `roles/compute/phase2.sh` →
the helmfile Loki release (`retention_period: 168h`), and it is **enforced** —
the Loki compactor runs with `retention_enabled: true`, so chunks older than
7 days are deleted. Log storage is therefore a **rolling 7-day window**, not
unbounded growth.

### Where logs live (two different things)

| | Location | Behaviour | A 7-day accumulation? |
|---|---|---|---|
| **Raw container logs** | **Compute** node, `/var/log/pods` | Capped at **50 MiB × 5 = 250 MiB per container** (RKE2 `--container-log-max-*`), rotated | **No** — fixed ceiling, already in the Compute estimate |
| **Loki log store** | **Storage** node — Loki's dedicated **MinIO** PVC (`nfs-csi`, `loki_minio_size: 50Gi` nominal) | Compressed chunks, **7-day** retention | **Yes** — this is the accumulation |

The OpenTelemetry agent tails all pod logs → OTel gateway → Loki → MinIO, so the
7-day accumulation is the **steady-state size of the Loki/MinIO store on the
Storage node**.

### The estimate (infra services only, no Commons)

| | Low | Typical | High |
|---|----:|--------:|-----:|
| Daily raw log volume (all infra pods + K8s/RKE2 system) | 0.5 GB/day | 2 GB/day | 5 GB/day |
| × 7 days (raw) | 3.5 GB | 14 GB | 35 GB |
| Loki chunk compression (gzip, text logs) | ÷10 | ÷8 | ÷5 |
| **Stored on the Storage node (MinIO) at steady state** | **~0.4 GB** | **~1.8 GB** | **~7 GB** |

**So ~7 days of infra-only logs is on the order of ~2 GB stored (≤7 GB worst
case)** — comfortably inside the 50 GiB MinIO PVC. It grows the **Storage**
node's NFS usage from "minutes of data" to this steady state over the first week.

Assumptions/caveats for the log figure:

- **Daily volume is the big unknown** — it scales with component log levels and
  cluster activity. Validate with `--measure` once a cluster has run ~a day and
  extrapolate.
- **Istio access logging is OFF** by default; **Kubernetes audit logging is OFF**
  — either would add a large separate stream.
- Compression is approximate; Loki typically achieves 5–15× on text logs.
- **Commons multiplies this.** Application pods add their own log streams once
  installed; size the MinIO PVC and Storage volume for the post-Commons rate.

### Metrics are separate

This section covers **logs** only. Prometheus **metrics** accumulate
independently (its own TSDB PVC on the Storage node, with its own retention) and
are **not** included in the figures above.

---

## Assumptions

1. **Base OS** is the Ubuntu 24.04 LTS **cloud server image**, present on **every
   node** (RP, Compute, Storage, Backup). Day-1 usage is **~3–5 GB**, but the
   **provisioning budget is 25 GB per node** (see the *Base OS — used today vs
   budget* section). A non-minimal Server-ISO install adds ~1.5–2.5 GB to day-1
   usage; **Desktop is not assumed**.
2. **`--no-install-recommends`** is used for all apt installs (as the automation
   does), keeping package footprints minimal.
3. **No application data.** PostgreSQL has only the post-`initdb` cluster (no
   Commons databases, no rows). NFS PVCs hold only infra telemetry accrued
   between helmfile-sync completion and the measurement — assumed **minutes**.
   For the 7-day steady state of the log store, see
   [Log accumulation](#log-accumulation-over-the-7-day-retention-window).
4. **Observability PVCs are `nfs-csi`-backed** (the default StorageClass), so
   Prometheus/Loki/MinIO/Grafana **data** is counted on the **Storage** node,
   while their **images** are counted on **Compute**.
5. **Container-image rows are on-disk** (content blobs + extracted overlay
   snapshots), roughly **1.3–1.6×** the registry pull size — the largest source
   of estimate uncertainty (hence the wide band on Compute).
6. **No cert-manager** on Compute: Rancher uses `tls: external` +
   `ingress.enabled: false`, so cert-manager images are not pulled.
7. **Single control-plane** (Production-Minimum): one etcd member, one set of
   system images. HA multiplies the system-image + etcd footprint per node.
8. **Logs** are bounded by RKE2's `--container-log-max-size=50Mi
   --container-log-max-files=5` per container; journald is default-capped.
9. **`public_access=false`** and **AI layer disabled** — no extra images.
10. Figures are **steady-state immediately post-install** and are estimates, not
    guarantees — image sizes drift across versions. **Validate on a real node**
    with `--measure`.

## How to validate against a live node

On each node, after infra and **before** the environment stage:

```bash
sudo ./storage-estimate.sh --measure --role compute
sudo ./storage-estimate.sh --measure --role storage
sudo ./storage-estimate.sh --measure --role reverse-proxy
```

It runs `du -sh` over the role's key paths (including a `/var/cache/apt`,
kernel, and snap breakdown so you can see the OS overhead) and prints `df -h /`,
so you can compare actual usage to the **Typical** column and adjust the model.

## What this does *not* cover

- **Production-scale application data** — the dominant long-term consumer. The
  Commons layer here is "installed + idle for a week"; it does **not** model
  beneficiary/transaction/document volume, which drives PostgreSQL DB growth,
  MinIO object growth, and Kafka topic retention. Size that from a usage model
  (e.g. *rows/objects per beneficiary × beneficiaries*).
- **Traffic-driven logs** — once citizen services flow, per-request logs
  (eSignet, Keycloak, Istio access logs) dominate the Loki store.
- **Backup repository growth** — sized from the PG/NFS data volume + retention.
