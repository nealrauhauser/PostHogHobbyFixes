# PostHog Hobby Deploy Fixes

Automated fixes for deploying PostHog self-hosted hobby edition. The upstream hobby compose (`docker-compose.hobby.yml`) is broken out of the box as of April 2026 — this repo provides a one-command setup script that works around all known issues.

## The Problem

PostHog's self-hosted hobby deploy assumes cloud infrastructure (managed Redis with TLS, specific schema state, correct env propagation). On a clean Docker Compose environment, you will encounter **12 distinct issues** that prevent the stack from functioning. None are documented in PostHog's official guides.

See [GITHUB_ISSUE.md](GITHUB_ISSUE.md) for the full bug report suitable for submission to PostHog's repo.

## Quick Start

```bash
# Create the sounder user (or whatever account you use)
# Then from that account:

git clone https://github.com/nealrauhauser/PostHogHobbyFixes.git
cd PostHogHobbyFixes
chmod +x setup.sh
./setup.sh
```

The script is idempotent — safe to re-run. It auto-detects `BIND_ADDR` from hostname.

## What `setup.sh` Does

1. Clones PostHog source and copies compose files
2. Creates `dev-services.env` with all required env var overrides (Redis hosts, TLS=false, health port)
3. Fixes port conflicts (Caddy, Temporal UI, MinIO, Postgres)
4. Creates `compose/start` and `compose/wait` entrypoint scripts
5. Patches ClickHouse projection mode config
6. Patches `person_sql.py` to remove DEFAULT clauses banned by Kafka engine
7. Generates `.env` with proper Fernet key, COMPOSE_FILE, CADDY_HOST
8. Creates `docker-compose.override.yml` with fixes for all Node services
9. Downloads GeoLite2 database for geo-IP services
10. Starts PostHog and waits for health check
11. Creates `~/update.sh` for future updates
12. Enables systemd auto-start on boot

## What `setup.sh` Does NOT Fix

**Issue 11: Database Schema Drift** — The Node plugin server expects columns and tables that the Django migrations don't create. After first boot, you must manually add them:

```sql
-- Connect to PostHog's Postgres (port 5433, not your app's 5432)
docker compose exec db psql -U posthog -d posthog -c "
  -- posthog_team
  ALTER TABLE posthog_team
    ADD COLUMN IF NOT EXISTS project_id bigint,
    ADD COLUMN IF NOT EXISTS secret_api_token varchar(200),
    ADD COLUMN IF NOT EXISTS person_processing_opt_out boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS heatmaps_opt_in boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS cookieless_server_hash_mode smallint NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS logs_settings jsonb,
    ADD COLUMN IF NOT EXISTS extra_settings jsonb,
    ADD COLUMN IF NOT EXISTS drop_events_older_than interval;
  UPDATE posthog_team SET project_id = id WHERE project_id IS NULL;
  ALTER TABLE posthog_team ALTER COLUMN project_id SET NOT NULL;

  -- posthog_organization
  ALTER TABLE posthog_organization
    ADD COLUMN IF NOT EXISTS available_product_features jsonb NOT NULL DEFAULT '[]'::jsonb;

  -- posthog_grouptypemapping
  ALTER TABLE posthog_grouptypemapping
    ADD COLUMN IF NOT EXISTS project_id integer;
  UPDATE posthog_grouptypemapping SET project_id = team_id WHERE project_id IS NULL;
  ALTER TABLE posthog_grouptypemapping ALTER COLUMN project_id SET NOT NULL;
"

# Then restart the affected services
docker compose restart ingestion-general plugins
```

There may be additional missing tables (e.g., `posthog_eventschema`). Check `ingestion-general` logs after restart and add any missing schema elements.

## Files in This Repo

| File | Purpose |
|------|---------|
| `setup.sh` | One-command automated deploy script. Source of truth for all fixes. |
| `ISSUES.md` | Detailed registry of all 12 issues with error messages, causes, and fixes. |
| `DEPLOY.md` | Step-by-step deploy guide with manual instructions for each step. |
| `GITHUB_ISSUE.md` | Bug report formatted for submission to [PostHog/posthog](https://github.com/PostHog/posthog/issues). |

## Generated Files (on the deploy host)

These are created by `setup.sh` in `~/posthog/`:

| File | Purpose |
|------|---------|
| `docker-compose.override.yml` | All service-level fixes (env_file, entrypoints, volumes, networks) |
| `dev-services.env` | All env var overrides for Node services (Redis hosts, TLS, health port) |
| `.env` | Secrets, COMPOSE_FILE path, noise suppression vars |
| `patches/person_sql.py` | Patched SQL templates mounted into web/worker containers |
| `compose/start` | Fixed entrypoint for web service |
| `compose/wait` | Dependency wait script (ClickHouse + Postgres) |

## Post-Update Checklist

Run after every `docker compose pull`:

```bash
cd ~/posthog

# Check for new 127.0.0.1 Redis defaults
docker compose run --rm plugins grep -rn '127\.0\.0\.1' /code/nodejs/dist --include='config.js'

# Check for new TLS defaults
docker compose run --rm plugins grep -rn 'REDIS_TLS' /code/nodejs/dist --include='config.js'

# Check valid PLUGIN_SERVER_MODE values
docker compose run --rm plugins node -e \
  "const t = require('/code/nodejs/dist/types'); console.log(Object.keys(t.stringToPluginServerMode))"

# Check health port hasn't moved
docker compose run --rm plugins grep -n 'DEFAULT_HTTP_SERVER_PORT' /code/nodejs/dist/common/config.js

# Verify everything is up
docker compose ps -a --format "table {{.Name}}\t{{.Status}}" | grep -v "Up \|Exited (0)"
```

## Related PostHog Issues

- [#37202](https://github.com/PostHog/posthog/issues/37202) — Plugin server not reachable
- [#38494](https://github.com/PostHog/posthog/issues/38494) — CDP_REDIS_TLS must be false for self-hosted
- [#15625](https://github.com/PostHog/posthog/issues/15625) — KafkaEngine DEFAULT column incompatibility

## License

MIT — use these fixes however you need.
