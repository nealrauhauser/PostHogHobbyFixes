# PostHog Self-Hosted Hobby Deploy: Comprehensive Bug Report

## Summary

PostHog's self-hosted hobby deployment (`docker-compose.hobby.yml` + `docker-compose.base.yml`) is broken out of the box as of April 2026. We encountered **12 distinct issues** deploying on a clean Ubuntu 24.04 system with Docker Compose. Each issue required manual intervention — none were caught by the bootstrap script or documented in PostHog's self-hosting guides.

The root cause is a pattern: **the hobby compose files and Docker images assume PostHog Cloud infrastructure** (managed Redis with TLS, specific schema state, correct env propagation) but ship without the configuration or migrations needed to work in a standalone Docker Compose environment.

## Workarounds Available

We've built an automated `setup.sh` and documented all 12 issues with fixes in a public repo:

**https://github.com/nealrauhauser/PostHogHobbyFixes**

The repo includes a one-command deploy script, a full issue registry, and a post-update checklist for surviving future `docker compose pull` breakage.

## Related Existing Issues

- [PostHog #37202](https://github.com/PostHog/posthog/issues/37202) — Plugin server not reachable (hobby deploy)
- [PostHog #38494](https://github.com/PostHog/posthog/issues/38494) — `CDP_REDIS_TLS: 'false'` needed for self-hosted
- [PostHog #15625](https://github.com/PostHog/posthog/issues/15625) — KafkaEngine doesn't support DEFAULT columns in `person_sql.py`

## Environment

- **OS**: Ubuntu 24.04 (amd64), 16 cores / 32GB RAM
- **Docker**: Docker Compose v2
- **PostHog images**: `posthog/posthog:latest-release`, `posthog/posthog-node:latest` (pulled 2026-04-05)
- **ClickHouse**: `clickhouse/clickhouse-server:25.12.5.44`

---

## Issue 1: ClickHouse Projection Mode Incompatibility

**Error**: `Code: 344. Projections are not supported for ReplacingMergeTree with deduplicate_merge_projection_mode = throw`

**Description**: ClickHouse 24.8+ changed the default `deduplicate_merge_projection_mode` from `drop` to `throw` ([ClickHouse PR #66672](https://github.com/ClickHouse/ClickHouse/pull/66672)). PostHog's migrations create projections on ReplacingMergeTree tables, which crashes under the new default.

**Workaround**: Add to `clickhouse/config.d/default.xml`:
```xml
<merge_tree>
    <deduplicate_merge_projection_mode>drop</deduplicate_merge_projection_mode>
    <lightweight_mutation_projection_mode>drop</lightweight_mutation_projection_mode>
</merge_tree>
```

**Suggested fix**: Pin a compatible ClickHouse config in the hobby compose, or add the `<merge_tree>` block to the shipped `default.xml`.

---

## Issue 2: KafkaEngine DEFAULT Columns (PostHog #15625)

**Error**: `Code: 36. KafkaEngine doesn't support DEFAULT/MATERIALIZED/EPHEMERAL expressions for columns`

**Description**: `posthog/models/person/sql.py` shares SQL templates between MergeTree and Kafka engine tables. Two columns (`is_deleted Int8 DEFAULT 0`, `version Int64 DEFAULT 1`) have DEFAULT clauses that are banned in Kafka engine since ClickHouse 23.3 ([ClickHouse PR #47138](https://github.com/ClickHouse/ClickHouse/pull/47138)). Five migrations (0004, 0009, 0013, 0014, 0029) reference the affected SQL.

**Additional problem**: The migration runner (`infi.clickhouse_orm`) records a migration as "applied" even when individual operations within it fail. This creates a state where the registry is ahead of reality, requiring a full data wipe to recover.

**Workaround**: Patch `person_sql.py` to remove DEFAULT clauses, mount via Docker volume.

**Suggested fix**: Split the SQL templates so Kafka engine tables don't inherit DEFAULT clauses.

---

## Issue 3: Caddy Proxy Binding

**Description**: The base compose sets `CADDY_HOST: 'http://localhost:8000'`. The `CADDYFILE` template uses `${CADDY_HOST}` which resolves at compose-parse time from the base default, not from runtime env. The hobby compose's override only takes effect at container runtime — too late for template expansion.

**Workaround**: Set `CADDY_HOST=http://:80` in `.env`.

**Suggested fix**: Move `CADDY_HOST` default to `.env.example` or document it in the hobby setup guide.

---

## Issue 4: Plugins Fernet Key Format

**Description**: The plugins service (Node.js) requires `ENCRYPTION_SALT_KEYS` to be a 32-character base64url string (24 random bytes). The hobby bootstrap script generates a random string that doesn't match this format. Additionally, the hobby compose doesn't pass `ENCRYPTION_SALT_KEYS` to the plugins container — it must be set explicitly.

**Workaround**: Generate with `python3 -c "import base64, os; print(base64.urlsafe_b64encode(os.urandom(24)).decode())"` and set in both `.env` and the compose override for the plugins service.

**Suggested fix**: Fix the bootstrap script to generate a valid Fernet key and pass it to the plugins service.

---

## Issue 5: Override File Silently Not Loaded

**Description**: Running `docker compose -f docker-compose.hobby.yml` disables auto-loading of `docker-compose.override.yml`. All memory limits, env vars, and volume mounts in the override are silently ignored.

**Workaround**: Set `COMPOSE_FILE=docker-compose.hobby.yml:docker-compose.override.yml` in `.env`.

**Suggested fix**: Document this requirement in the hobby setup guide, or use `include:` in `docker-compose.hobby.yml`.

---

## Issue 6: Node Services Redis — Fragmented Host Configuration

**Error**: `😡 [recording-api] Redis error encountered! host: 127.0.0.1:6379 Enough of this, I quit!`

**Description**: Each Node sub-service defines its own `*_REDIS_HOST` env var with a default of `127.0.0.1`. Setting `REDIS_URL` alone is insufficient — five separate variables must all be set:

| Env Var | Default |
|---------|---------|
| `REDIS_URL` | `redis://127.0.0.1` |
| `CDP_REDIS_HOST` | `127.0.0.1` |
| `LOGS_REDIS_HOST` | `127.0.0.1` |
| `TRACES_REDIS_HOST` | `127.0.0.1` |
| `SESSION_RECORDING_API_REDIS_HOST` | `127.0.0.1` |

The hobby compose's `dev-services.env` only sets `REDIS_URL`. The other four silently fall back to localhost.

**Workaround**: Set all five in `dev-services.env`.

**Suggested fix**: Derive all `*_REDIS_HOST` vars from `REDIS_URL` when not explicitly set, or set them all in the hobby `dev-services.env`.

---

## Issue 7: Node Services Redis — TLS Enabled by Default in Docker (Related: #38494)

**Error**: `ETIMEDOUT` connecting to `redis7:6379` (correct host, correct port, TCP connectivity confirmed with curl)

**Description**: `isProdEnv()` returns `true` inside the Docker image (ships with `NODE_ENV=production`). This causes `LOGS_REDIS_TLS` and `TRACES_REDIS_TLS` to default to `true`. The hobby deploy runs plain Redis without TLS — the TLS ClientHello gets no response, causing a TCP timeout that presents as `ETIMEDOUT`.

This is especially confusing because the error message says the correct host and port, and `curl` confirms TCP connectivity works. The timeout is at the TLS handshake layer, not the TCP layer.

**Additional problem**: The hobby compose only applies `env_file: dev-services.env` to the `plugins` service. Six Node services need it:
- `plugins`
- `ingestion-general`
- `ingestion-logs`
- `ingestion-traces`
- `ingestion-sessionreplay`
- `recording-api`

**Workaround**: Set `LOGS_REDIS_TLS=false` and `TRACES_REDIS_TLS=false` in `dev-services.env`, and add `env_file: dev-services.env` to all Node services in the override.

**Suggested fix**: Don't default TLS to `true` for self-hosted deploys, or set all `*_REDIS_TLS=false` in the hobby `dev-services.env`.

---

## Issue 8: Invalid PLUGIN_SERVER_MODE

**Error**: `Error: Invalid PLUGIN_SERVER_MODE ingestion-v2-combined`

**Description**: The `ingestion-v2-combined` mode was removed from `stringToPluginServerMode` in the Node image, but `docker-compose.hobby.yml` still sets it for the `ingestion-general` service.

Valid modes (as of 2026-04-05): `ingestion-v2`, `ingestion-logs`, `ingestion-traces`, `ingestion-errortracking`, `recording-api`, `local-cdp`, `evaluation-scheduler`, and various `cdp-*` variants.

**Workaround**: Override `PLUGIN_SERVER_MODE: "ingestion-v2"` for `ingestion-general`.

**Suggested fix**: Update `docker-compose.hobby.yml` when mode names change.

---

## Issue 9: temporal-django-worker Binary Removed

**Error**: `./bin/temporal-django-worker: No such file or directory` (exit code 127, crash loop)

**Description**: The `temporal-django-worker` binary was removed from the `posthog/posthog` image. It's not in `./bin/`, not available as a Django management command — fully gone. But `docker-compose.hobby.yml` still defines the service and references the binary, causing a crash loop.

**Workaround**: Override with a no-op entrypoint: `entrypoint: ["echo", "temporal-django-worker disabled"]`

**Suggested fix**: Remove or conditionally skip the `temporal-django-worker` service in the hobby compose.

---

## Issue 10: Plugin Server Health Check — Dead Redis Heartbeat + Port Change

**Error**: Validation page shows "Plugin server · Node — Error" despite all 20 internal health checks passing.

**Description**: Two problems:

1. **Dead heartbeat**: The Django web service checks `@posthog-plugin-server/ping` in Redis (`posthog/utils.py:725`). The Node plugin server **no longer writes this key** — the heartbeat code was removed from the image. The key is always `nil`, so `is_plugin_server_alive()` always returns `false`.

2. **Port change**: `DEFAULT_HTTP_SERVER_PORT` moved from `8001` to `6738` in `common/config.js`. The hobby compose still declares `8001/tcp`.

**Proof**:
```bash
# Health endpoint works (on the new port)
curl -s http://plugins:6738/_health
# → {"status":"ok","checks":{"ingestion-consumer-events_plugin_ingestion":"ok",...all ok...}}

# But the Redis key is nil
redis-cli GET "@posthog-plugin-server/ping"
# → (nil)

# Heartbeat writer doesn't exist
grep -rn 'plugin-server/ping' /code/nodejs/dist/ --include='*.js'
# → nothing
```

**Workaround**: Set `HTTP_SERVER_PORT=8001` in `dev-services.env`. Add a sidecar container to write the Redis ping key every 10 seconds.

**Suggested fix**: Either restore the Redis heartbeat in the Node plugin server, or update `is_plugin_server_alive()` to use the HTTP health endpoint instead.

---

## Issue 11: Database Schema Drift — Missing Columns and Tables

**Error**: `column t.project_id does not exist`, `column t.secret_api_token does not exist`, `column o.available_product_features does not exist`, `relation "posthog_eventschema" does not exist`

**Description**: The Node plugin server (`posthog/posthog-node:latest`) contains raw SQL queries that reference columns and tables not present in the database created by the Django migrations in `posthog/posthog:latest-release`. Missing schema elements include:

**posthog_team** (missing columns):
- `project_id` (bigint)
- `secret_api_token` (varchar)
- `person_processing_opt_out` (boolean)
- `heatmaps_opt_in` (boolean)
- `cookieless_server_hash_mode` (smallint)
- `logs_settings` (jsonb)
- `extra_settings` (jsonb)
- `drop_events_older_than` (interval)

**posthog_organization** (missing columns):
- `available_product_features` (jsonb)

**posthog_grouptypemapping** (missing columns):
- `project_id` (integer)

**Missing tables**:
- `posthog_eventschema`

This is the most critical issue — without these, the ingestion pipeline crash-loops and **no events are processed**. The capture API accepts events into Kafka, but they're never consumed into ClickHouse.

**Root cause**: The Python and Node codebases ship as separate Docker images (`posthog/posthog` vs `posthog/posthog-node`). The Node image's SQL queries reference schema that the Django image's migrations don't create — either because the migrations are gated behind feature flags, are enterprise-only, or the Node image was built from a newer commit than the Django image.

**Workaround**: Manually `ALTER TABLE` to add missing columns, `CREATE TABLE` for missing tables. This is unsustainable as an ongoing strategy.

**Suggested fix**: Either (a) ensure the hobby `latest-release` Django and Node images are built from the same commit with all required migrations included, or (b) add a schema compatibility check to the Node plugin server startup that fails with a clear message listing missing schema elements instead of crash-looping.

---

## Issue 12: Compose Variable Warnings (Cosmetic)

**Noise**: `WARN The "TLS_BLOCK" / "ELAPSED" / "TIMEOUT" variable is not set`

**Description**: The upstream compose references Caddy template variables that are not set in the hobby deploy.

**Workaround**: Add `TLS_BLOCK=`, `ELAPSED=`, `TIMEOUT=` to `.env`.

---

## Systemic Pattern

These aren't isolated bugs — they're symptoms of a structural problem:

1. **Fragmented config**: Each Node sub-service defines its own env vars with localhost/TLS defaults that silently break in Docker Compose
2. **`isProdEnv()` gate**: Docker images ship as "production", enabling cloud features (TLS, specific schemas) that hobby deploys don't support
3. **Split release cadence**: Python and Node images ship independently, creating schema mismatches between the migration state and the query expectations
4. **Silent failures**: Env vars fall back to wrong defaults without errors, migrations record success on partial failure, health checks use stale mechanisms
5. **No hobby CI**: There appears to be no automated test that boots the hobby compose from scratch and verifies basic event ingestion works end-to-end

We've built a comprehensive `setup.sh` automation and `docker-compose.override.yml` that works around all of these, but it requires updating after every `docker compose pull` as new breakage is introduced.

## Reproduction

1. Clean Ubuntu 24.04 machine with Docker Compose
2. Clone PostHog: `git clone https://github.com/posthog/posthog.git --depth 1`
3. Copy `docker-compose.base.yml` and `docker-compose.hobby.yml`
4. `docker compose -f docker-compose.hobby.yml up -d`
5. Observe failures in order listed above
