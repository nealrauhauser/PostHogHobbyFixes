#!/bin/bash
# PostHog Hobby Deploy — Smoke Tests
# Run from sounder@<host> in ~/posthog
#
# Tests every layer of the PostHog stack in dependency order.
# Each section is independent — failures don't block later tests.
#
# Usage:
#   cd ~/posthog && /home/repoman/HBbackend/PostHog/smoke_test.sh
#
# Exit code: number of failed tests (0 = all passed)

set -o pipefail
cd "${POSTHOG_DIR:-$HOME/posthog}" 2>/dev/null || { echo "FAIL: can't cd to posthog dir"; exit 1; }

PASS=0
FAIL=0
WARN=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
warn() { echo "  ~ $1"; WARN=$((WARN + 1)); }

# Suppress compose variable warnings
export COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.hobby.yml:docker-compose.override.yml}"

echo "╔══════════════════════════════════════════╗"
echo "║  PostHog Hobby Deploy — Smoke Tests      ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ═══════════════════════════════════════════════════════════════════════
# SECTION 1: Container Health
# Check that all expected containers are running. Containers that
# exit 0 (one-shot init jobs) are OK. Anything restarting or exited
# with a non-zero code is a failure.
# ═══════════════════════════════════════════════════════════════════════

echo "1. Container Health"
echo "───────────────────"

UNHEALTHY=$(docker compose ps -a --format "{{.Name}} {{.Status}}" 2>/dev/null \
    | grep -v "Up \|Exited (0)" \
    | grep -v "^$" || true)

if [ -z "$UNHEALTHY" ]; then
    pass "All containers healthy"
else
    echo "$UNHEALTHY" | while read -r line; do
        fail "Container: $line"
    done
fi

# Check specific critical services are Up (not just exist)
for svc in web worker plugins ingestion-general redis7 clickhouse kafka db proxy; do
    status=$(docker compose ps --format "{{.Status}}" "$svc" 2>/dev/null | head -1)
    if echo "$status" | grep -q "Up"; then
        pass "$svc is running"
    else
        fail "$svc is NOT running (status: ${status:-not found})"
    fi
done

echo ""

# ═══════════════════════════════════════════════════════════════════════
# SECTION 2: Database (Postgres)
# Verify PostHog's internal Postgres is accepting connections and has
# the expected schema — including columns that the Node image requires
# but Django migrations may not have created (Issue 11).
# ═══════════════════════════════════════════════════════════════════════

echo "2. Database (Postgres)"
echo "──────────────────────"

DB_CMD="docker compose exec -T db psql -U posthog -d posthog -t -A"

# Basic connectivity
if $DB_CMD -c "SELECT 1" 2>/dev/null | grep -q "1"; then
    pass "Postgres accepting connections"
else
    fail "Postgres not responding"
fi

# Schema drift checks (Issue 11) — columns the Node image expects
for col in project_id secret_api_token person_processing_opt_out heatmaps_opt_in cookieless_server_hash_mode logs_settings extra_settings drop_events_older_than; do
    if $DB_CMD -c "SELECT column_name FROM information_schema.columns WHERE table_name='posthog_team' AND column_name='$col'" 2>/dev/null | grep -q "$col"; then
        pass "posthog_team.$col exists"
    else
        fail "posthog_team.$col MISSING (Issue 11)"
    fi
done

# posthog_organization.available_product_features
if $DB_CMD -c "SELECT column_name FROM information_schema.columns WHERE table_name='posthog_organization' AND column_name='available_product_features'" 2>/dev/null | grep -q "available_product_features"; then
    pass "posthog_organization.available_product_features exists"
else
    fail "posthog_organization.available_product_features MISSING (Issue 11)"
fi

# posthog_grouptypemapping.project_id
if $DB_CMD -c "SELECT column_name FROM information_schema.columns WHERE table_name='posthog_grouptypemapping' AND column_name='project_id'" 2>/dev/null | grep -q "project_id"; then
    pass "posthog_grouptypemapping.project_id exists"
else
    fail "posthog_grouptypemapping.project_id MISSING (Issue 11)"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════
# SECTION 3: ClickHouse
# Verify ClickHouse is healthy and has the projection mode fix applied.
# ═══════════════════════════════════════════════════════════════════════

echo "3. ClickHouse"
echo "─────────────"

CH_CMD="docker compose exec -T clickhouse clickhouse-client --query"

if $CH_CMD "SELECT 1" 2>/dev/null | grep -q "1"; then
    pass "ClickHouse accepting connections"
else
    fail "ClickHouse not responding"
fi

# Check projection mode setting (Issue 1)
PROJ_MODE=$($CH_CMD "SELECT value FROM system.merge_tree_settings WHERE name='deduplicate_merge_projection_mode'" 2>/dev/null | tr -d '[:space:]')
if [ "$PROJ_MODE" = "drop" ]; then
    pass "deduplicate_merge_projection_mode = drop"
else
    fail "deduplicate_merge_projection_mode = '$PROJ_MODE' (should be 'drop', Issue 1)"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════
# SECTION 4: Redis
# Verify Redis is responding and the plugin server heartbeat key is
# being written (Issue 10).
# ═══════════════════════════════════════════════════════════════════════

echo "4. Redis"
echo "────────"

REDIS_CMD="docker compose exec -T redis7 redis-cli"

if $REDIS_CMD PING 2>/dev/null | grep -q "PONG"; then
    pass "Redis PING → PONG"
else
    fail "Redis not responding"
fi

# Heartbeat key (Issue 10)
PING_VAL=$($REDIS_CMD GET "@posthog-plugin-server/ping" 2>/dev/null | tr -d '[:space:]')
if [ -n "$PING_VAL" ] && [ "$PING_VAL" != "(nil)" ]; then
    pass "Plugin server heartbeat key present ($PING_VAL)"
else
    fail "Plugin server heartbeat key MISSING (Issue 10)"
fi

# Check DB size (sanity — should have some keys if PostHog is working)
DBSIZE=$($REDIS_CMD DBSIZE 2>/dev/null | grep -o '[0-9]*')
if [ "${DBSIZE:-0}" -gt 0 ]; then
    pass "Redis has $DBSIZE keys"
else
    warn "Redis has 0 keys (may be normal on fresh install)"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════
# SECTION 5: Kafka (Redpanda)
# Verify Kafka is healthy and the main ingestion topic exists.
# ═══════════════════════════════════════════════════════════════════════

echo "5. Kafka"
echo "────────"

if docker compose exec -T kafka rpk cluster health 2>/dev/null | grep -q "HEALTHY\|healthy"; then
    pass "Kafka cluster healthy"
else
    # rpk might not have 'cluster health', try alternative
    if docker compose exec -T kafka rpk topic list 2>/dev/null | grep -q "events_plugin_ingestion"; then
        pass "Kafka responding (topic list works)"
    else
        fail "Kafka not responding"
    fi
fi

# Check for main ingestion topic
if docker compose exec -T kafka rpk topic list 2>/dev/null | grep -q "events_plugin_ingestion"; then
    pass "events_plugin_ingestion topic exists"
else
    fail "events_plugin_ingestion topic MISSING"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════
# SECTION 6: Web (Django)
# Verify the Django web tier is responding with HTTP 200 on /_health.
# This is what the official installer checks — it only proves Django
# and Caddy work, not that ingestion is functional.
# ═══════════════════════════════════════════════════════════════════════

echo "6. Web (Django + Caddy)"
echo "───────────────────────"

HTTP_CODE=$(curl -so /dev/null -w '%{http_code}' "http://localhost:8000/_health" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "Web /_health → 200"
else
    # Try via proxy (port 80/443)
    HTTP_CODE=$(curl -so /dev/null -w '%{http_code}' "http://localhost/_health" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
        pass "Web /_health → 200 (via proxy)"
    else
        fail "Web /_health → $HTTP_CODE"
    fi
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════
# SECTION 7: Plugin Server (Node)
# Verify the plugin server's HTTP health endpoint returns ok on the
# correct port (Issue 10: moved from 8001 to 6738, we override back).
# Also check that it's not crash-looping on Redis TLS (Issue 7) or
# schema drift (Issue 11).
# ═══════════════════════════════════════════════════════════════════════

echo "7. Plugin Server (Node)"
echo "───────────────────────"

# Try port 8001 first (our override), then 6738 (upstream default)
PLUGIN_HEALTH=""
for port in 8001 6738; do
    PLUGIN_HEALTH=$(docker compose exec -T web curl -s "http://plugins:${port}/_health" 2>/dev/null || true)
    if echo "$PLUGIN_HEALTH" | grep -q '"status":"ok"'; then
        pass "Plugin server /_health → ok (port $port)"
        break
    fi
done

if ! echo "$PLUGIN_HEALTH" | grep -q '"status":"ok"'; then
    fail "Plugin server health endpoint unreachable on 8001 or 6738"
fi

# Count how many checks are ok
OK_COUNT=$(echo "$PLUGIN_HEALTH" | grep -o '"ok"' | wc -l | tr -d ' ')
if [ "${OK_COUNT:-0}" -gt 0 ]; then
    pass "Plugin server: $OK_COUNT internal checks passing"
else
    warn "Plugin server: could not parse internal check count"
fi

# Check for recent crash-loop indicators
RESTART_COUNT=$(docker compose ps --format "{{.Status}}" plugins 2>/dev/null | grep -c "Restarting" || true)
if [ "$RESTART_COUNT" -gt 0 ]; then
    fail "plugins container is restarting"
else
    pass "plugins container is stable (not restarting)"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════
# SECTION 8: Ingestion Pipeline
# Verify all ingestion containers are running and not crash-looping.
# These are the services that consume events from Kafka and write to
# ClickHouse. If any are down, events accumulate in Kafka unprocessed.
# ═══════════════════════════════════════════════════════════════════════

echo "8. Ingestion Pipeline"
echo "─────────────────────"

for svc in ingestion-general ingestion-logs ingestion-traces ingestion-sessionreplay recording-api; do
    status=$(docker compose ps --format "{{.Status}}" "$svc" 2>/dev/null | head -1)
    if echo "$status" | grep -q "Up"; then
        # Check it's been up more than 60 seconds (not bounce-looping)
        if echo "$status" | grep -qE "Up [0-9]+ (minute|hour|day)"; then
            pass "$svc stable"
        elif echo "$status" | grep -qE "Up About a minute|Up [6-9][0-9] second|Up [1-9][0-9][0-9]+ second"; then
            pass "$svc running (recently started)"
        else
            warn "$svc up but very recently restarted: $status"
        fi
    else
        fail "$svc is NOT running (status: ${status:-not found})"
    fi
done

# Check for Redis TLS errors (Issue 7) in any Node service
TLS_ERRORS=$(docker compose logs --tail=20 plugins ingestion-general ingestion-logs ingestion-traces 2>/dev/null \
    | grep -c "ETIMEDOUT\|Enough of this" || true)
if [ "$TLS_ERRORS" -gt 0 ]; then
    fail "Redis TLS/connection errors in recent logs ($TLS_ERRORS occurrences)"
else
    pass "No Redis connection errors in recent logs"
fi

# Check for schema drift errors (Issue 11) in ingestion logs
SCHEMA_ERRORS=$(docker compose logs --tail=20 ingestion-general plugins 2>/dev/null \
    | grep -c "does not exist\|42703\|42P01" || true)
if [ "$SCHEMA_ERRORS" -gt 0 ]; then
    fail "Schema drift errors in recent logs ($SCHEMA_ERRORS occurrences)"
else
    pass "No schema drift errors in recent logs"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════
# SECTION 9: End-to-End Event Capture
# Send a test event via the capture API and verify it was accepted.
# This tests: Caddy proxy → Django capture → Kafka.
# NOTE: Does not verify the event reaches ClickHouse (that requires
# a working ingestion pipeline + waiting for processing).
# ═══════════════════════════════════════════════════════════════════════

echo "9. Event Capture (End-to-End)"
echo "─────────────────────────────"

# Get the API key from PostHog's Postgres
API_KEY=$($DB_CMD -c "SELECT api_token FROM posthog_team LIMIT 1" 2>/dev/null | tr -d '[:space:]')

if [ -z "$API_KEY" ]; then
    warn "No project API key found — skipping capture test (complete setup wizard first)"
else
    CAPTURE_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "http://localhost:8000/batch/" \
        -H "Content-Type: application/json" \
        -d "{
            \"api_key\": \"$API_KEY\",
            \"batch\": [{
                \"event\": \"smoke_test_ping\",
                \"distinct_id\": \"smoke-test-runner\",
                \"properties\": {\"source\": \"smoke_test.sh\"},
                \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\"
            }]
        }" 2>/dev/null)

    CAPTURE_CODE=$(echo "$CAPTURE_RESPONSE" | tail -1)
    CAPTURE_BODY=$(echo "$CAPTURE_RESPONSE" | head -1)

    if [ "$CAPTURE_CODE" = "200" ]; then
        pass "Capture API accepted event (HTTP 200)"
    else
        fail "Capture API returned HTTP $CAPTURE_CODE: $CAPTURE_BODY"
    fi
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════
# SECTION 10: Configuration Checks
# Verify that known-required env vars and config patches are in place.
# Catches regressions after docker compose pull.
# ═══════════════════════════════════════════════════════════════════════

echo "10. Configuration"
echo "─────────────────"

# dev-services.env checks
for var in CDP_REDIS_HOST LOGS_REDIS_HOST TRACES_REDIS_HOST SESSION_RECORDING_API_REDIS_HOST LOGS_REDIS_TLS TRACES_REDIS_TLS HTTP_SERVER_PORT; do
    if grep -q "^${var}=" dev-services.env 2>/dev/null; then
        pass "$var set in dev-services.env"
    else
        fail "$var MISSING from dev-services.env"
    fi
done

# .env checks
for var in COMPOSE_FILE CADDY_HOST SKIP_SERVICE_VERSION_REQUIREMENTS; do
    if grep -q "^${var}=" .env 2>/dev/null; then
        pass "$var set in .env"
    else
        fail "$var MISSING from .env"
    fi
done

# Override file exists
if [ -f docker-compose.override.yml ]; then
    pass "docker-compose.override.yml exists"
else
    fail "docker-compose.override.yml MISSING"
fi

# GeoLite2 database
if [ -f share/GeoLite2-City.mmdb ]; then
    pass "GeoLite2-City.mmdb present"
else
    warn "GeoLite2-City.mmdb missing (geo-IP lookups disabled)"
fi

# person_sql.py patch (Issue 2)
if [ -f patches/person_sql.py ]; then
    if grep -q "is_deleted Int8 DEFAULT" patches/person_sql.py 2>/dev/null; then
        fail "patches/person_sql.py still has DEFAULT clause (Issue 2)"
    else
        pass "patches/person_sql.py patched correctly"
    fi
else
    warn "patches/person_sql.py not found (may not be needed if migrations already ran)"
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════
# SECTION 11: Version Drift Detection
# Check if the Node image expects things the current config doesn't
# provide. Run after docker compose pull to catch new breakage.
# ═══════════════════════════════════════════════════════════════════════

echo "11. Version Drift Detection"
echo "───────────────────────────"

# New 127.0.0.1 defaults we haven't overridden
NEW_LOCALHOST=$(docker compose exec -T plugins sh -c "grep -rn '127\.0\.0\.1' /code/nodejs/dist --include='config.js' 2>/dev/null" 2>/dev/null \
    | grep -v "test\|node_modules" \
    | grep -oP '\w+_REDIS_HOST' \
    | sort -u || true)

for var in $NEW_LOCALHOST; do
    if grep -q "^${var}=" dev-services.env 2>/dev/null; then
        pass "$var is overridden"
    else
        fail "$var defaults to 127.0.0.1 but is NOT in dev-services.env"
    fi
done

# New TLS defaults
NEW_TLS=$(docker compose exec -T plugins sh -c "grep -rn 'REDIS_TLS' /code/nodejs/dist --include='config.js' 2>/dev/null" 2>/dev/null \
    | grep -v "test\|node_modules" \
    | grep -oP '\w+_REDIS_TLS' \
    | sort -u || true)

for var in $NEW_TLS; do
    if grep -q "^${var}=" dev-services.env 2>/dev/null; then
        pass "$var is overridden"
    else
        fail "$var defaults to TLS=true but is NOT in dev-services.env"
    fi
done

# Health port check
CURRENT_PORT=$(docker compose exec -T plugins sh -c "grep 'DEFAULT_HTTP_SERVER_PORT' /code/nodejs/dist/common/config.js 2>/dev/null" 2>/dev/null \
    | grep -oP '\d+' || true)
CONFIGURED_PORT=$(grep "^HTTP_SERVER_PORT=" dev-services.env 2>/dev/null | cut -d= -f2)

if [ -n "$CURRENT_PORT" ] && [ -n "$CONFIGURED_PORT" ]; then
    if [ "$CURRENT_PORT" != "$CONFIGURED_PORT" ]; then
        fail "Health port drift: image default=$CURRENT_PORT, configured=$CONFIGURED_PORT"
    else
        pass "Health port matches ($CONFIGURED_PORT)"
    fi
fi

echo ""

# ═══════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════

echo "══════════════════════════════════════════"
echo "Results: $PASS passed, $FAIL failed, $WARN warnings"
echo "══════════════════════════════════════════"

if [ $FAIL -gt 0 ]; then
    echo ""
    echo "See PostHogFuckups.md for fixes: https://github.com/nealrauhauser/PostHogHobbyFixes"
fi

exit $FAIL
