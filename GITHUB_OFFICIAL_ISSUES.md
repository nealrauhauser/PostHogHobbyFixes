# What Breaks When You Run PostHog's Official Hobby Installer

**Date tested:** 2026-04-05
**Official install command:** `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/posthog/posthog/HEAD/bin/deploy-hobby)"`
**Source:** https://posthog.com/docs/self-host

## Summary

PostHog's official self-host installer (`bin/deploy-hobby`) completes without errors, reports "Done!", and gives you a working web UI. **But zero events are ingested.** The capture API accepts events into Kafka, but every ingestion container is either crash-looping or dead. You have a pretty dashboard with no data pipeline behind it.

The official script does these things correctly:
- Clones the repo
- Installs Docker
- Copies compose files and `dev-services.env`
- Downloads GeoLite2
- Creates entrypoint scripts
- Generates `.env` with secrets
- Runs `docker compose up`
- Waits for the web health check

The web health check passes because Django and Caddy start fine. The script exits with "Done! 🎉". Everything behind the web tier is broken.

## Failure Catalog

These failures occur in order. Each one blocks progress — you must fix them sequentially because each crash prevents the next issue from being discovered.

### Failure 1: Compose Variable Warnings (Cosmetic)

**Every `docker compose` command prints:**
```
WARN[0000] The "TLS_BLOCK" variable is not set. Defaulting to a blank string.
WARN[0000] The "ELAPSED" variable is not set. Defaulting to a blank string.
WARN[0000] The "TIMEOUT" variable is not set. Defaulting to a blank string.
```

**Cause:** The official `.env` template sets `TLS_BLOCK` from a `$3` argument that nobody passes. `ELAPSED` and `TIMEOUT` are Caddy template vars referenced in the compose but never defined.

**Impact:** Noise only, but 5 warning lines on every command makes troubleshooting harder.

---

### Failure 2: ClickHouse Migrations Crash

**Error:**
```
Code: 344. DB::Exception: Projections are not supported for ReplacingMergeTree
with deduplicate_merge_projection_mode = throw
```

**Cause:** ClickHouse 24.8+ changed the default from `drop` to `throw`. PostHog migrations create projections on ReplacingMergeTree tables. The official script doesn't patch the ClickHouse config.

**Impact:** ClickHouse schema is incomplete. Some tables and projections don't exist.

---

### Failure 3: ClickHouse Kafka Table Creation Fails

**Error:**
```
Code: 36. DB::Exception: KafkaEngine doesn't support DEFAULT/MATERIALIZED/EPHEMERAL
expressions for columns
```

**Cause:** `person_sql.py` shares SQL templates between MergeTree and Kafka engine tables. Two columns have `DEFAULT` clauses banned in Kafka engine since ClickHouse 23.3. Known upstream issue: [PostHog #15625](https://github.com/PostHog/posthog/issues/15625).

**Trap:** The migration runner (`infi.clickhouse_orm`) records the migration as "applied" even when individual operations within it fail. The registry is now ahead of reality. A `docker compose down && docker compose up` won't re-run the migration — you need a full data wipe.

**Impact:** Kafka consumer tables don't exist. Events can't flow from Kafka to ClickHouse.

---

### Failure 4: `plugins` Container Crash-Loops — Redis Wrong Host

**Error:**
```
😡 [recording-api] Redis error encountered! host: 127.0.0.1:6379 Enough of this, I quit!
```

**Cause:** The upstream `dev-services.env` sets `REDIS_URL=redis://redis7:6379/` but does NOT set four other Redis host vars that each Node sub-service defines independently:

| Env Var | Default | Needed |
|---------|---------|--------|
| `CDP_REDIS_HOST` | `127.0.0.1` | `redis7` |
| `LOGS_REDIS_HOST` | `127.0.0.1` | `redis7` |
| `TRACES_REDIS_HOST` | `127.0.0.1` | `redis7` |
| `SESSION_RECORDING_API_REDIS_HOST` | `127.0.0.1` | `redis7` |

The PostHog Node config system merges sub-configs via JavaScript spread. Each sub-service defines its own Redis env var. `overrideWithEnv()` only replaces a default if the env var is present. Setting just `REDIS_URL` is insufficient.

**Impact:** `plugins` container restarts every ~10 seconds.

---

### Failure 5: All `ingestion-*` Containers Crash-Loop — Same Redis Error

**Error:** Same as Failure 4: `host: 127.0.0.1:6379 Enough of this, I quit!`

**Cause:** Even if you add the Redis vars to `dev-services.env`, the ingestion containers don't read that file. The official compose only applies `env_file: dev-services.env` to `web`, `worker`, and a few Python services. Six Node services are missing it:

- `plugins`
- `ingestion-general`
- `ingestion-logs`
- `ingestion-traces`
- `ingestion-sessionreplay`
- `recording-api`

**Impact:** All event ingestion is dead.

---

### Failure 6: Redis ETIMEDOUT — TLS Handshake Timeout

**Error:**
```
ETIMEDOUT connecting to redis7:6379
```

**Cause:** This is the most confusing failure. The host is correct (`redis7`, not `127.0.0.1`). The port is correct (`6379`). TCP connectivity works (`curl` confirms it). But the connection times out.

The reason: `isProdEnv()` returns `true` inside the Docker image (it ships with `NODE_ENV=production`). This enables TLS for Redis connections by default:

```javascript
LOGS_REDIS_TLS: isProdEnv() ? true : false,  // true in Docker
TRACES_REDIS_TLS: isProdEnv() ? true : false, // true in Docker
```

The hobby deploy runs plain Redis without TLS. The Node client sends a TLS ClientHello. Redis doesn't speak TLS. The handshake hangs until TCP timeout. The error says `ETIMEDOUT` not `ECONNREFUSED` — a critical clue that this is a protocol mismatch, not a network problem.

Related: [PostHog #38494](https://github.com/PostHog/posthog/issues/38494)

**Impact:** Even with correct Redis hosts, connections fail on TLS handshake.

---

### Failure 7: `ingestion-general` Invalid PLUGIN_SERVER_MODE

**Error:**
```
Error: Invalid PLUGIN_SERVER_MODE ingestion-v2-combined
```

**Cause:** `ingestion-v2-combined` was removed from the valid mode enum in the Node image. The hobby compose still sets it. Valid modes now include `ingestion-v2`, `ingestion-logs`, `ingestion-traces`, etc.

**Impact:** `ingestion-general` (the main event ingestion consumer) can't start.

---

### Failure 8: `temporal-django-worker` Crash-Loops (Exit 127)

**Error:**
```
./bin/temporal-django-worker: No such file or directory
```

**Cause:** The `temporal-django-worker` binary was removed from the `posthog/posthog` image. Not in `./bin/`, not as a Django management command — fully gone. The hobby compose still defines the service and references the binary.

**Note:** The official `compose/temporal-django-worker` script also doesn't call `/compose/wait` first, so even if the binary existed, it would try to start before Postgres and ClickHouse are ready.

**Impact:** Non-critical for core analytics (temporal handles async exports), but the crash-loop consumes resources and clutters logs.

---

### Failure 9: Validation Page Shows "Plugin Server — Error"

**Error:** The setup wizard validation page shows 9 successful checks and 1 error: "Plugin server · Node — Error"

**Cause:** The Django web service checks plugin server health by reading `@posthog-plugin-server/ping` from Redis (`posthog/utils.py:725`). The plugin server is supposed to write a timestamp to this key every few seconds. **The Node plugin server no longer writes this key** — the heartbeat code was removed from the image.

```python
# posthog/utils.py:723-728
def is_plugin_server_alive() -> bool:
    try:
        ping = get_client().get("@posthog-plugin-server/ping")
        return bool(ping and parser.isoparse(ping) > timezone.now() - relativedelta(seconds=30))
    except BaseException:
        return False
```

The `/_health` HTTP endpoint returns `status: ok` with all 20 internal checks passing. But the validation page doesn't use it.

**Impact:** Can't proceed past the setup wizard. The "Validate requirements" button never goes green.

---

### Failure 10: Plugin Server Health Port Changed

**Error:** Health endpoint unreachable on port 8001

**Cause:** `DEFAULT_HTTP_SERVER_PORT` was changed from `8001` to `6738` in `common/config.js`. The hobby compose still declares `8001/tcp`. The plugin server starts and is healthy — but on the wrong port.

```javascript
// /code/nodejs/dist/common/config.js
exports.DEFAULT_HTTP_SERVER_PORT = 6738;  // was 8001
```

**Impact:** Even if you try to manually check plugin server health, you'll hit the wrong port.

---

### Failure 11: Database Schema Drift — Missing Columns

**Error:**
```
column t.project_id does not exist
column t.secret_api_token does not exist
column o.available_product_features does not exist
```

**Cause:** The Node plugin server (`posthog/posthog-node:latest`) contains raw SQL queries that reference columns not present in the database created by the Django migrations in `posthog/posthog:latest-release`:

**posthog_team** — missing 8 columns:
- `project_id` (bigint)
- `secret_api_token` (varchar)
- `person_processing_opt_out` (boolean)
- `heatmaps_opt_in` (boolean)
- `cookieless_server_hash_mode` (smallint)
- `logs_settings` (jsonb)
- `extra_settings` (jsonb)
- `drop_events_older_than` (interval)

**posthog_organization** — missing:
- `available_product_features` (jsonb)

**posthog_grouptypemapping** — missing:
- `project_id` (integer)

The Python and Node codebases ship as separate Docker images. The Node image's SQL queries reference schema that the Django image's migrations don't create.

**Impact:** `ingestion-general` and `plugins` crash-loop on every event processing attempt. Events accumulate in Kafka but are never consumed into ClickHouse.

---

### Failure 12: Missing Tables

**Error:**
```
relation "posthog_eventschema" does not exist
```

**Cause:** Same schema drift as Failure 11, but now entire tables are missing, not just columns.

**Impact:** Even after patching missing columns, ingestion crashes on missing tables. The whack-a-mole continues.

---

## Net Result

After running the official installer with zero intervention:

| Component | Status |
|-----------|--------|
| Web UI (Django) | Works |
| Caddy proxy | Works |
| ClickHouse | Partially initialized (broken migrations) |
| Kafka | Running but events accumulate unprocessed |
| Redis | Running but unreachable from Node services |
| `plugins` | Crash-looping |
| `ingestion-general` | Crash-looping |
| `ingestion-logs` | Crash-looping |
| `ingestion-traces` | Crash-looping |
| `ingestion-sessionreplay` | Crash-looping |
| `recording-api` | Crash-looping |
| `temporal-django-worker` | Crash-looping |
| Event ingestion | **Zero events processed** |
| Setup wizard | Blocked (plugin server validation fails) |

The official health check (`/_health`) returns 200 because it only checks the Django web tier. The installer reports success. The user sees a working UI with zero data flowing through it.

## Workarounds

All 12 issues have workarounds documented and automated in:

**https://github.com/nealrauhauser/PostHogHobbyFixes**

## Related Issues

- [PostHog #37202](https://github.com/PostHog/posthog/issues/37202) — Plugin server not reachable
- [PostHog #38494](https://github.com/PostHog/posthog/issues/38494) — CDP_REDIS_TLS must be false for self-hosted
- [PostHog #15625](https://github.com/PostHog/posthog/issues/15625) — KafkaEngine DEFAULT column incompatibility
