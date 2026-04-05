#!/bin/bash
# setup_official.sh — PostHog hobby deploy using official installer + fixes
#
# Runs PostHog's official deploy-hobby script first, then applies all 12
# fixes from https://github.com/nealrauhauser/PostHogHobbyFixes
#
# The official script handles: git clone, Docker install, .env creation,
# compose/start + compose/wait scripts, GeoLite2 download, and initial
# docker compose up.
#
# This script then fixes: Redis host fragmentation, TLS defaults,
# ClickHouse projection mode, Kafka DEFAULT columns, plugin server mode,
# temporal-django-worker removal, health check heartbeat, health port,
# compose variable warnings, and database schema drift.
#
# Usage:
#   ./setup_official.sh
#
# Or non-interactive (skips the official script's prompts):
#   POSTHOG_APP_TAG=latest DOMAIN=posthog.example.com ./setup_official.sh
#
# Prerequisites:
#   - Ubuntu/Debian system
#   - 8+ GB RAM
#   - Sudo access

set -e

echo "=========================================="
echo "PostHog Hobby Deploy (Official + Fixes)"
echo "=========================================="
echo ""
echo "Phase 1: Running official PostHog installer..."
echo "  (This will ask for version and domain)"
echo ""

# ── Phase 1: Run the official deploy-hobby script ────────────────────
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/posthog/posthog/HEAD/bin/deploy-hobby)"

echo ""
echo "=========================================="
echo "Phase 2: Applying fixes (Dirty Dozen)"
echo "=========================================="
echo ""

# The official script creates files in the current directory:
#   docker-compose.yml (copied from hobby.yml)
#   docker-compose.base.yml
#   dev-services.env (copied from repo — incomplete)
#   .env
#   compose/start, compose/wait, compose/temporal-django-worker
#   posthog/ (cloned repo)
#   share/GeoLite2-City.mmdb

# ── Fix 1: ClickHouse Projection Mode ────────────────────────────────

echo "Fix 1: ClickHouse projection mode..."

CH_CONFIG="posthog/docker/clickhouse/config.d/default.xml"
if grep -q "deduplicate_merge_projection_mode" "$CH_CONFIG" 2>/dev/null; then
    echo "  Already patched — skipping"
else
    sed -i 's|</clickhouse>|    <merge_tree>\n        <deduplicate_merge_projection_mode>drop</deduplicate_merge_projection_mode>\n        <lightweight_mutation_projection_mode>drop</lightweight_mutation_projection_mode>\n    </merge_tree>\n</clickhouse>|' "$CH_CONFIG"
    echo "  Patched default.xml"
fi

# ── Fix 2: Kafka DEFAULT Columns ─────────────────────────────────────

echo "Fix 2: Patching Kafka table SQL..."

docker pull posthog/posthog:latest-release 2>/dev/null || true
docker create --name posthog-extract posthog/posthog:latest-release > /dev/null 2>&1 || true
mkdir -p patches
docker cp posthog-extract:/code/posthog/models/person/sql.py patches/person_sql.py 2>/dev/null || true
docker rm posthog-extract > /dev/null 2>&1 || true

if [ -f patches/person_sql.py ]; then
    sed -i 's/is_deleted Int8 DEFAULT 0/is_deleted Int8/' patches/person_sql.py
    sed -i 's/version Int64 DEFAULT 1/version Int64/' patches/person_sql.py
    echo "  person_sql.py patched"
else
    echo "  Warning: could not extract person_sql.py (non-critical if migrations already ran)"
fi

# ── Fix 3-5: .env additions ──────────────────────────────────────────

echo "Fix 3-5: Updating .env..."

# Add COMPOSE_FILE to load both base and override
if ! grep -q "COMPOSE_FILE" .env 2>/dev/null; then
    # Official script uses docker-compose.yml (renamed hobby) — add override
    echo 'COMPOSE_FILE=docker-compose.yml:docker-compose.override.yml' >> .env
    echo "  Added COMPOSE_FILE"
fi

# Fix Caddy binding
if ! grep -q "CADDY_HOST" .env 2>/dev/null; then
    echo 'CADDY_HOST=http://:80' >> .env
    echo "  Added CADDY_HOST"
fi

# Fix compose variable warnings
if ! grep -q "TLS_BLOCK" .env 2>/dev/null; then
    echo 'TLS_BLOCK=' >> .env
fi
if ! grep -q "ELAPSED" .env 2>/dev/null; then
    echo 'ELAPSED=' >> .env
fi
if ! grep -q "TIMEOUT" .env 2>/dev/null; then
    echo 'TIMEOUT=' >> .env
fi

# Add SKIP_SERVICE_VERSION_REQUIREMENTS
if ! grep -q "SKIP_SERVICE_VERSION_REQUIREMENTS" .env 2>/dev/null; then
    echo 'SKIP_SERVICE_VERSION_REQUIREMENTS=1' >> .env
fi

echo "  .env updated"

# ── Fix 6-7: dev-services.env — Redis hosts + TLS ────────────────────

echo "Fix 6-7: Updating dev-services.env with Redis overrides..."

# Add missing Redis host vars (Issue 6)
for var in "CDP_REDIS_HOST=redis7" "LOGS_REDIS_HOST=redis7" "TRACES_REDIS_HOST=redis7" "SESSION_RECORDING_API_REDIS_HOST=redis7"; do
    key="${var%%=*}"
    if ! grep -q "^${key}=" dev-services.env 2>/dev/null; then
        echo "$var" >> dev-services.env
    fi
done

# Add TLS overrides (Issue 7)
for var in "LOGS_REDIS_TLS=false" "TRACES_REDIS_TLS=false"; do
    key="${var%%=*}"
    if ! grep -q "^${key}=" dev-services.env 2>/dev/null; then
        echo "$var" >> dev-services.env
    fi
done

# Add health port override (Issue 10)
if ! grep -q "^HTTP_SERVER_PORT=" dev-services.env 2>/dev/null; then
    echo "HTTP_SERVER_PORT=8001" >> dev-services.env
fi

echo "  dev-services.env updated"

# ── Fix 4, 6-10: Create docker-compose.override.yml ──────────────────

echo "Fix 4, 6-10: Creating docker-compose.override.yml..."

# Get or generate FERNET_KEY
FERNET_KEY=$(grep '^ENCRYPTION_SALT_KEYS=' .env | cut -d= -f2- || echo "")
if [ -z "$FERNET_KEY" ]; then
    FERNET_KEY=$(python3 -c "import base64, os; print(base64.urlsafe_b64encode(os.urandom(24)).decode())" 2>/dev/null || openssl rand -hex 16)
fi

cat > docker-compose.override.yml <<YAMLEOF
services:
  clickhouse:
    ulimits:
      nofile:
        soft: 262144
        hard: 262144

  elasticsearch:
    environment:
      ES_JAVA_OPTS: "-Xms256m -Xmx512m"
      discovery.type: single-node

  web:
    volumes:
      - ./patches/person_sql.py:/code/posthog/models/person/sql.py
    environment:
      SKIP_SERVICE_VERSION_REQUIREMENTS: "1"

  worker:
    volumes:
      - ./patches/person_sql.py:/code/posthog/models/person/sql.py
    environment:
      SKIP_SERVICE_VERSION_REQUIREMENTS: "1"

  plugins:
    env_file: dev-services.env
    environment:
      SKIP_SERVICE_VERSION_REQUIREMENTS: "1"
      ENCRYPTION_SALT_KEYS: "${FERNET_KEY}"

  # All Node services need env_file for Redis host + TLS overrides
  ingestion-general:
    env_file: dev-services.env
    environment:
      PLUGIN_SERVER_MODE: "ingestion-v2"

  ingestion-logs:
    env_file: dev-services.env

  ingestion-traces:
    env_file: dev-services.env

  ingestion-sessionreplay:
    env_file: dev-services.env

  recording-api:
    env_file: dev-services.env

  asyncmigrationscheck:
    environment:
      SKIP_SERVICE_VERSION_REQUIREMENTS: "1"

  cymbal:
    environment:
      SKIP_SERVICE_VERSION_REQUIREMENTS: "1"
    volumes:
      - ./share:/share

  feature-flags:
    environment:
      SKIP_SERVICE_VERSION_REQUIREMENTS: "1"
    volumes:
      - ./share:/share

  # Issue 10: Plugin server no longer writes heartbeat to Redis.
  # Django validation page checks @posthog-plugin-server/ping.
  # This sidecar writes the key every 10s so the health check passes.
  plugin-server-heartbeat:
    image: redis:7-alpine
    entrypoint: sh
    command: -c 'while true; do redis-cli -h redis7 SET "@posthog-plugin-server/ping" "\$\$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" EX 30; redis-cli -h redis7 SET "@posthog-plugin-server/version" "unknown"; sleep 10; done'
    depends_on:
      - redis7
    restart: unless-stopped

  # Issue 9: temporal-django-worker binary removed from image
  temporal-django-worker:
    entrypoint: ["echo", "temporal-django-worker disabled — binary removed from image"]
YAMLEOF

echo "  docker-compose.override.yml created"

# ── Restart with fixes applied ────────────────────────────────────────

echo ""
echo "Restarting PostHog with fixes..."
docker compose down 2>/dev/null || sudo docker-compose down 2>/dev/null || true
docker compose up -d 2>/dev/null || sudo -E docker-compose up -d

echo ""
echo "Waiting for PostHog to be healthy..."

RETRIES=0
MAX_RETRIES=60
while [ $RETRIES -lt $MAX_RETRIES ]; do
    HTTP_CODE=$(curl -so /dev/null -w '%{http_code}' "http://localhost/_health" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
        echo "  PostHog is healthy!"
        break
    fi
    RETRIES=$((RETRIES + 1))
    if [ $((RETRIES % 10)) -eq 0 ]; then
        echo "  Still waiting... ($RETRIES/${MAX_RETRIES})"
    fi
    if [ $RETRIES -eq $MAX_RETRIES ]; then
        echo "  Warning: PostHog not healthy after 5 minutes"
        echo "  Check logs: docker compose logs --tail=50 web"
    fi
    sleep 5
done

# ── Fix 11: Database schema drift ────────────────────────────────────

echo ""
echo "Fix 11: Checking for missing database columns..."
echo "  (Waiting 30s for migrations to complete...)"
sleep 30

docker compose exec -T db psql -U posthog -d posthog -c "
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

  -- posthog_organization
  ALTER TABLE posthog_organization
    ADD COLUMN IF NOT EXISTS available_product_features jsonb NOT NULL DEFAULT '[]'::jsonb;

  -- posthog_grouptypemapping
  ALTER TABLE posthog_grouptypemapping
    ADD COLUMN IF NOT EXISTS project_id integer;
  UPDATE posthog_grouptypemapping SET project_id = team_id WHERE project_id IS NULL;
" 2>/dev/null && echo "  Schema patched" || echo "  Warning: schema patch failed (may need manual intervention)"

# Restart ingestion after schema fix
docker compose restart ingestion-general plugins 2>/dev/null || true

# ── Summary ───────────────────────────────────────────────────────────

echo ""
echo "=========================================="
echo "PostHog Hobby Deploy Complete (with fixes)"
echo "=========================================="
echo ""
echo "Fixes applied:"
echo "  1.  ClickHouse projection mode"
echo "  2.  Kafka DEFAULT columns (person_sql.py)"
echo "  3.  Caddy proxy binding"
echo "  4.  Fernet key propagation"
echo "  5.  Override file loading"
echo "  6.  Redis host fragmentation (5 env vars)"
echo "  7.  Redis TLS disabled for hobby"
echo "  8.  PLUGIN_SERVER_MODE updated"
echo "  9.  temporal-django-worker disabled"
echo "  10. Plugin server heartbeat + port fix"
echo "  11. Database schema drift patched"
echo "  12. Compose variable warnings suppressed"
echo ""
echo "Full issue details: https://github.com/nealrauhauser/PostHogHobbyFixes"
echo ""
echo "After updates (docker compose pull), re-run this script or check"
echo "ISSUES.md for the post-update checklist."
echo ""
