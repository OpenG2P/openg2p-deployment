# Bug report — eSignet & mock-identity `postgres-init` ship as post-install hooks (deadlocks `helm --wait`)

> **File this against:** [`OpenG2P/openg2p-commons-deployment`](https://github.com/OpenG2P/openg2p-commons-deployment)
> **Affected charts:** `openg2p-commons-services` `0.0.0-develop` (subcharts `esignet-1.4.3`, `mock-identity-system-0.9.5`)
> **Severity:** High — a fresh `helm upgrade --install --wait` of commons-services **fails every time**; eSignet and mock-identity never start.

## Symptom

On a clean install, `commons-services-esignet` and `commons-services-mock-identity-system` crashloop:

```
Caused by: org.postgresql.util.PSQLException: ERROR: relation "key_alias" does not exist
  at io.mosip.kernel.keymanagerservice.helper.KeymanagerDBHelper.init(KeymanagerDBHelper.java:103)
```

`helm status commons-services` ends as:

```
STATUS: failed
DESCRIPTION: Release "commons-services" failed: ... Deployment/commons-services-esignet not ready.
             Progress deadline exceeded ... Deployment/commons-services-mock-identity-system not ready.
```

The databases (`mosip_esignet`, `mosip_mockidentitysystem`) and their users **exist** (created by commons-base `postgres-init`) — only the **keymanager schema** (`key_alias`, `key_store`, …) is missing inside them.

## Root cause

eSignet and mock-identity each embed the keymanager library, which needs the keymanager schema **in their own database**. That schema is created by each subchart's `postgres-init` Job. Those Jobs are rendered as **post-install hooks**:

```
$ helm get hooks commons-services -n <ns>
# Source: openg2p-commons-services/charts/esignet/templates/postgresInit/job.yaml
metadata:
  name: commons-services-esignet-postgres-init
  annotations:
    helm.sh/hook: post-install          # <-- still a hook
    helm.sh/hook-delete-policy: before-hook-creation
# Source: openg2p-commons-services/charts/mock-identity-system/templates/postgresInit/job.yaml
  annotations:
    helm.sh/hook: post-install          # <-- still a hook
```

This deadlocks `helm --wait`:

1. helm applies the main resources, then **waits** for the eSignet/mock Deployments to become Ready.
2. They crashloop (`key_alias does not exist`) — the schema isn't there yet.
3. The schema-creating Job is a **post-install hook**, which only runs **after** the release is Ready.
4. → `--wait` hits the progress deadline, the release is marked **failed**, the post-install hooks **never run**, the schema is never created.

**keymanager (standalone) is unaffected** because its `postgres-init` renders as a *regular resource* (it appears in `helm get manifest`, not `helm get hooks`) — it runs during the main apply, concurrent with the Deployment, so the Deployment recovers and `--wait` succeeds.

## Why the existing mitigation doesn't work

The parent chart already *tries* to neutralise the hook for all three (keymanager, eSignet, mock-identity) by overriding the annotations to `null`:

```yaml
# openg2p-commons-services/values.yaml
esignet:
  postgresInit:
    commonAnnotations:
      "helm.sh/hook": null
      "helm.sh/hook-weight": null
      "helm.sh/hook-delete-policy": null
```

This **takes effect for keymanager but silently fails for eSignet/mock**, even though:
- all three subcharts bundle the same `common` library (`2.30.0`),
- all three templates render annotations identically (`common.tplvalues.render` of `.Values.postgresInit.commonAnnotations`),
- all three subchart defaults set the same `helm.sh/hook: post-install`.

i.e. the chart is relying on Helm's "set a subchart-default key to `null` to delete it" behaviour, which is **unreliable across subcharts/versions**. A production chart should not depend on it.

## Suggested fix (in `openg2p-commons-deployment`)

**Make the eSignet/mock `postgres-init` run as regular resources — don't rely on `null` deletion.** Concretely, the most robust option:

- Remove the `helm.sh/hook*` keys from the **subchart's own** `values.yaml` defaults (`esignet`/`mock-identity-system` → `postgresInit.commonAnnotations`), so there is nothing to "delete" from the parent. Then the Job applies alongside the Deployment (keymanager's working pattern): the pod crashloops for ~40s, the Job creates the schema, the pod recovers, and `--wait` succeeds.
- `pre-install` is **not** a viable alternative here — the Job uses the `commons-services-esignet` ServiceAccount, which is a regular resource created during the main apply (after pre-install hooks would run).

**Add a CI guard:** fail the chart lint if any `postgres-init` Job still carries a `helm.sh/hook` annotation after rendering:

```bash
helm template . | awk 'BEGIN{RS="\n---\n"} /kind: Job/ && /mosipid\/postgres-init/ && /helm.sh\/hook:/ {print "FAIL: postgres-init still a hook"; bad=1} END{exit bad}'
```

## Reproduction

```bash
helm upgrade --install commons-services openg2p/openg2p-commons-services \
  -n <ns> --version 0.0.0-develop --wait --timeout 20m \
  --set global.baseDomain=<domain> --set postgresql.enabled=false \
  --set global.postgresqlHost=<host> --set global.postgresqlSecret=commons-postgresql
# → fails after 20m; esignet + mock-identity-system in CrashLoopBackOff (key_alias does not exist)
```

## Operator-side workaround (already implemented in the OpenG2P 3-node automation)

Until the chart is fixed, the production env automation
(`automation/production/roles/environment/phase2.sh`) self-heals: it runs the
commons-services install in the background and, once the ServiceAccounts exist,
materialises the post-install `postgres-init` hooks as **regular Jobs**, then
restarts the affected deployments — which lets the backgrounded `helm --wait`
finish cleanly. This is a bridge; the real fix belongs in the chart.

Manual equivalent:

```bash
helm get hooks commons-services -n <ns> \
  | awk 'BEGIN{RS="\n---\n"} /kind: Job/ && /mosipid\/postgres-init/ {print "---"; print}' \
  | grep -vE '^[[:space:]]*"?helm\.sh/hook(-delete-policy|-weight)?"?:' \
  | kubectl apply -n <ns> -f -
kubectl -n <ns> rollout restart deploy commons-services-esignet commons-services-mock-identity-system
```
