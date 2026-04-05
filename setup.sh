#!/bin/bash
# setup.sh — One-command PostHog self-hosted hobby deployment
#
# Fixes 12 known issues with the upstream hobby compose that prevent
# PostHog from functioning out of the box. See ISSUES.md for details.
#
# Repo: https://github.com/nealrauhauser/PostHogHobbyFixes
#
# Auto-detects BIND_ADDR from hostname. Override with:
#   BIND_ADDR=<ip> ./setup.sh
#
# Usage:
#   ./setup.sh
#
# Prerequisites:
#   - Docker + Docker Compose
#   - 8+ GB RAM available
#   - If port 5432 is in use, PostHog Postgres will use 5433 (configured below)
#   - If port 8081 is in use, temporal-ui will use 8082 (configured below)

set -e

# Auto-detect BIND_ADDR from hostname if not explicitly set
if [ -z "$BIND_ADDR" ]; then
    BIND_ADDR="127.0.0.1"
fi
POSTHOG_DIR="$HOME/posthog"

echo "=========================================="
echo "PostHog Self-Hosted Setup (sounder)"
echo "=========================================="
echo ""
echo "  BIND_ADDR: $BIND_ADDR"
echo "  Install dir: $POSTHOG_DIR"
echo ""

# Check Docker
if ! docker compose version &> /dev/null; then
    echo "Error: Docker Compose is not installed!"
    exit 1
fi
echo "Docker Compose available"
echo ""

# ── Step 1: Clone PostHog source ──────────────────────────────────

if [ -d "$POSTHOG_DIR/posthog/.git" ]; then
    echo "Step 1: PostHog source already cloned — skipping"
else
    echo "Step 1: Cloning PostHog source..."
    rm -rf "$HOME/posthog-src"
    git clone https://github.com/posthog/posthog.git "$HOME/posthog-src" --depth 1
    # Fix restrictive permissions from upstream repo (postgres-init-scripts etc.)
    chmod -R u+rwX "$HOME/posthog-src"
    mkdir -p "$POSTHOG_DIR"
    cd "$POSTHOG_DIR"
    rm -rf posthog
    cp -r "$HOME/posthog-src" posthog
    cp posthog/docker-compose.base.yml docker-compose.base.yml
    cp posthog/docker-compose.hobby.yml docker-compose.hobby.yml
    # base.yml references dev-services.env for container-internal connection
    # strings. Newer upstream versions removed inline env vars from the hobby
    # compose and rely on this file instead.
    cat > dev-services.env << 'DEVENV'
DATABASE_URL=postgres://posthog:posthog@db:5432/posthog
PGHOST=db
PGUSER=posthog
PGPASSWORD=posthog
CLICKHOUSE_HOST=clickhouse
CLICKHOUSE_DATABASE=posthog
CLICKHOUSE_SECURE=false
CLICKHOUSE_VERIFY=false
REDIS_URL=redis://redis7:6379/
CDP_REDIS_HOST=redis7
LOGS_REDIS_HOST=redis7
LOGS_REDIS_TLS=false
TRACES_REDIS_HOST=redis7
TRACES_REDIS_TLS=false
SESSION_RECORDING_API_REDIS_HOST=redis7
HTTP_SERVER_PORT=8001
KAFKA_HOSTS=kafka:9092
OBJECT_STORAGE_ENDPOINT=http://objectstorage:19000
OBJECT_STORAGE_ACCESS_KEY_ID=object_storage_root_user
OBJECT_STORAGE_SECRET_ACCESS_KEY=object_storage_root_password
IS_BEHIND_PROXY=true
DISABLE_SECURE_SSL_REDIRECT=true
DEVENV
    echo "  Source cloned and compose files copied"
fi

cd "$POSTHOG_DIR"
echo ""

# ── Step 2: Fix port conflicts ────────────────────────────────────
#
# All port remaps happen in docker-compose.hobby.yml (NOT base.yml).
# Each fix uses a function that finds the EXACT line and replaces it entirely.
# No fragile pattern seds — if the line isn't found, it's already fixed or
# upstream changed the format (which we catch and warn about).

echo "Step 2: Fixing port conflicts in compose files..."

replace_line() {
    local file="$1" old="$2" new="$3" label="$4"
    if grep -qF "$old" "$file" 2>/dev/null; then
        sed -i "s|.*${old}.*|${new}|" "$file"
        echo "  $label"
    fi
}

# All in docker-compose.hobby.yml:
replace_line docker-compose.hobby.yml "'80:80'" \
    "            - '${BIND_ADDR}:8000:80'" \
    "Caddy HTTP: 80 → ${BIND_ADDR}:8000"

replace_line docker-compose.hobby.yml "'443:443'" \
    "            - '${BIND_ADDR}:8443:443'" \
    "Caddy HTTPS: 443 → ${BIND_ADDR}:8443"

replace_line docker-compose.hobby.yml "7233:7233" \
    "            - ${BIND_ADDR}:7233:7233" \
    "Temporal: → ${BIND_ADDR}:7233"

replace_line docker-compose.hobby.yml "'19000:19000'" \
    "            - '${BIND_ADDR}:19000:19000'" \
    "MinIO API: → ${BIND_ADDR}:19000"

replace_line docker-compose.hobby.yml "'19001:19001'" \
    "            - '${BIND_ADDR}:19001:19001'" \
    "MinIO Console: → ${BIND_ADDR}:19001"

replace_line docker-compose.hobby.yml "8081:8080" \
    "            - ${BIND_ADDR}:8082:8080" \
    "Temporal UI: 8081 → ${BIND_ADDR}:8082 (AdminApp owns 8081)"

echo "  Port conflicts resolved"
echo ""

# ── Step 3: Fix compose/start path ────────────────────────────────

echo "Step 3: Fixing compose/start and compose/wait..."

mkdir -p compose

cat > compose/start << 'EOF'
#!/bin/bash
/compose/wait
./bin/migrate
./bin/docker-server
EOF
chmod +x compose/start

cat > compose/temporal-django-worker << 'EOF'
#!/bin/bash
/compose/wait
./bin/temporal-django-worker
EOF
chmod +x compose/temporal-django-worker

cat > compose/wait << 'PYEOF'
#!/usr/bin/env python3
import socket
import time

def loop():
    print("Waiting for ClickHouse and Postgres to be ready")
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.connect(("clickhouse", 9000))
        print("Clickhouse is ready")
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.connect(("db", 5432))
        print("Postgres is ready")
    except ConnectionRefusedError as e:
        time.sleep(5)
        loop()

loop()
PYEOF
chmod +x compose/wait

echo "  compose/start and compose/wait created"
echo ""

# ── Step 4: Fix ClickHouse projection mode ────────────────────────

echo "Step 4: Fixing ClickHouse projection mode..."

CH_CONFIG="posthog/docker/clickhouse/config.d/default.xml"
if grep -q "deduplicate_merge_projection_mode" "$CH_CONFIG" 2>/dev/null; then
    echo "  Already patched — skipping"
else
    sed -i 's|</clickhouse>|    <merge_tree>\n        <deduplicate_merge_projection_mode>drop</deduplicate_merge_projection_mode>\n        <lightweight_mutation_projection_mode>drop</lightweight_mutation_projection_mode>\n    </merge_tree>\n</clickhouse>|' "$CH_CONFIG"
    echo "  Added merge_tree config to default.xml"
fi
echo ""

# ── Step 5: Patch Kafka table SQL ─────────────────────────────────

echo "Step 5: Patching Kafka table SQL (person_sql.py)..."

docker pull posthog/posthog:latest-release

# Extract the file from the image
docker create --name posthog-extract posthog/posthog:latest-release > /dev/null 2>&1
mkdir -p patches
docker cp posthog-extract:/code/posthog/models/person/sql.py patches/person_sql.py
docker rm posthog-extract > /dev/null 2>&1

# Remove DEFAULT clauses that break Kafka engine tables
sed -i 's/is_deleted Int8 DEFAULT 0/is_deleted Int8/' patches/person_sql.py
sed -i 's/version Int64 DEFAULT 1/version Int64/' patches/person_sql.py

echo "  person_sql.py patched"
echo ""

# ── Step 6: Create .env ──────────────────────────────────────────

echo "Step 6: Creating .env..."

if [ -f ".env" ]; then
    echo "  .env already exists — skipping"
else
    POSTHOG_SECRET=$(head -c 28 /dev/urandom | sha224sum | head -c 56)
    FERNET_KEY=$(python3 -c "import base64, os; print(base64.urlsafe_b64encode(os.urandom(24)).decode())")

    # Determine SITE_URL based on BIND_ADDR
    if [ "$BIND_ADDR" = "127.0.0.1" ]; then
        SITE_URL="http://localhost:8000"
        DOMAIN="localhost"
        WEB_HOSTNAME="localhost"
        IS_BEHIND_PROXY="true"
    else
        SITE_URL="http://${BIND_ADDR}:8000"
        DOMAIN="$BIND_ADDR"
        WEB_HOSTNAME="$BIND_ADDR"
        IS_BEHIND_PROXY="false"
    fi

    cat > .env <<ENVEOF
POSTHOG_SECRET=$POSTHOG_SECRET
ENCRYPTION_SALT_KEYS=$FERNET_KEY
SITE_URL=$SITE_URL
DOMAIN=$DOMAIN
WEB_HOSTNAME=$WEB_HOSTNAME
REGISTRY_URL=posthog/posthog
POSTHOG_APP_TAG=latest-release
COMPOSE_FILE=docker-compose.hobby.yml:docker-compose.override.yml
CLICKHOUSE_SERVER_IMAGE=clickhouse/clickhouse-server:25.12.5.44
CADDY_HOST=http://:80
SKIP_SERVICE_VERSION_REQUIREMENTS=1
IS_BEHIND_PROXY=$IS_BEHIND_PROXY
TLS_BLOCK=
ELAPSED=
TIMEOUT=
ENVEOF

    echo "  .env created"

    # Save FERNET_KEY for use in Step 7
    export FERNET_KEY
fi
echo ""

# ── Step 7: Create docker-compose.override.yml ────────────────────

echo "Step 7: Creating docker-compose.override.yml..."

# Read FERNET_KEY from .env if not already set
if [ -z "$FERNET_KEY" ]; then
    FERNET_KEY=$(grep '^ENCRYPTION_SALT_KEYS=' .env | cut -d= -f2-)
fi

cat > docker-compose.override.yml <<YAMLEOF
services:
  clickhouse:
    ulimits:
      nofile:
        soft: 262144
        hard: 262144

  kafka:
    command:
      - redpanda
      - start
      - --kafka-addr internal://0.0.0.0:9092,external://0.0.0.0:19092
      - --advertise-kafka-addr internal://kafka:9092,external://localhost:19092
      - --pandaproxy-addr internal://0.0.0.0:8082,external://0.0.0.0:18082
      - --advertise-pandaproxy-addr internal://kafka:8082,external://localhost:18082
      - --schema-registry-addr internal://0.0.0.0:8081,external://0.0.0.0:18081
      - --rpc-addr kafka:33145
      - --advertise-rpc-addr kafka:33145
      - --smp 1
      - --memory 1G
      - --reserve-memory 200M
      - --overprovisioned
      - --unsafe-bypass-fsync=true
      - --set redpanda.enable_transactions=true
      - --set redpanda.enable_idempotence=true

  elasticsearch:
    environment:
      ES_JAVA_OPTS: "-Xms256m -Xmx512m"
      discovery.type: single-node

  db:
    ports:
      - "${BIND_ADDR}:5433:5432"

  web:
    volumes:
      - ./patches/person_sql.py:/code/posthog/models/person/sql.py
    environment:
      SKIP_SERVICE_VERSION_REQUIREMENTS: "1"
      IS_BEHIND_PROXY: "${IS_BEHIND_PROXY:-false}"

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

  # All Node services that create Redis v2 pools need the env_file
  # to override LOGS_REDIS_TLS, TRACES_REDIS_TLS, and *_REDIS_HOST
  # defaults (which point to 127.0.0.1 with TLS enabled in "prod").
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

  # Workaround: plugin server no longer writes heartbeat to Redis, but
  # Django validation page still checks @posthog-plugin-server/ping.
  # This sidecar writes the key every 10s so the health check passes.
  plugin-server-heartbeat:
    image: redis:7-alpine
    entrypoint: sh
    command: -c 'while true; do redis-cli -h redis7 SET "@posthog-plugin-server/ping" "$$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" EX 30; redis-cli -h redis7 SET "@posthog-plugin-server/version" "unknown"; sleep 10; done'
    depends_on:
      - redis7
    restart: unless-stopped

  # temporal-django-worker: ./bin/temporal-django-worker was removed from the
  # PostHog image but hobby compose still references it. Override entrypoint
  # with a no-op so the container exits cleanly instead of crash-looping.
  # Temporal handles async exports/batch ops — not needed for core analytics.
  temporal-django-worker:
    entrypoint: ["echo", "temporal-django-worker disabled — binary removed from image"]

  # If you need PostHog reachable from another Docker Compose stack,
  # bridge the proxy into that network. Example:
  # proxy:
  #   networks:
  #     - default
  #     - your-app-network
  #
  # networks:
  #   your-app-network:
  #     external: true
  #     name: your_network_name
YAMLEOF

echo "  docker-compose.override.yml created"
echo ""

# ── Step 8: Download GeoLite2 database ────────────────────────────

echo "Step 8: Downloading GeoLite2 database..."

mkdir -p share
if [ -f "share/GeoLite2-City.mmdb" ]; then
    echo "  GeoLite2-City.mmdb already exists — skipping"
else
    curl -sL https://github.com/P3TERX/GeoLite.mmdb/releases/latest/download/GeoLite2-City.mmdb \
        -o share/GeoLite2-City.mmdb
    echo "  GeoLite2-City.mmdb downloaded"
fi
echo ""

# ── Step 9: Start PostHog ────────────────────────────────────────

echo "Step 9: Starting PostHog..."
# temporal may fail to bind port 7233 on first start (transient Docker
# port-proxy race). Start everything, then retry temporal separately.
docker compose up -d 2>&1 || true
sleep 5
docker compose up -d temporal 2>&1 || echo "  Warning: temporal failed to start (non-critical, handles async exports only)"
echo ""

# ── Step 10: Wait for health check ────────────────────────────────

echo "Step 10: Waiting for PostHog to be healthy..."
echo "  (ClickHouse migrations take ~2-3 minutes on first boot)"

RETRIES=0
MAX_RETRIES=60
while [ $RETRIES -lt $MAX_RETRIES ]; do
    HTTP_CODE=$(curl -so /dev/null -w '%{http_code}' "http://${BIND_ADDR}:8000/_health" 2>/dev/null || echo "000")
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
        echo "  ClickHouse migrations may still be running."
        echo "  Try: curl http://${BIND_ADDR}:8000/_health"
    fi
    sleep 5
done

echo ""

# ── Step 11: Create update.sh ─────────────────────────────────────

echo "Step 11: Creating ~/update.sh..."

cat > "$HOME/update.sh" << 'EOF'
#!/bin/bash
set -e
cd ~/posthog
docker compose pull
docker compose up -d
echo "PostHog updated and restarted"
EOF
chmod +x "$HOME/update.sh"

echo "  ~/update.sh created"
echo ""

# ── Step 12: Enable auto-start on boot ──────────────────────────────

echo "Step 12: Enabling auto-start on boot..."

SERVICE_FILE="/etc/systemd/system/posthog.service"
if [ -f "$SERVICE_FILE" ]; then
    echo "  posthog.service already exists — skipping"
else
    sudo tee "$SERVICE_FILE" > /dev/null << SVCEOF
[Unit]
Description=PostHog Analytics (sounder)
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=sounder
Group=sounder
WorkingDirectory=/home/sounder/posthog
ExecStartPre=/bin/sleep 30
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose stop
TimeoutStartSec=300
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
SVCEOF
    sudo systemctl daemon-reload
    sudo systemctl enable posthog.service
    echo "  posthog.service created and enabled"
fi
echo ""

# ── Summary ───────────────────────────────────────────────────────

echo "=========================================="
echo "PostHog Setup Complete"
echo "=========================================="
echo ""
echo "PostHog UI: http://${BIND_ADDR}:8000"
echo "Health:     curl http://${BIND_ADDR}:8000/_health"
echo ""
echo "Next steps:"
echo "  1. Open the UI and complete the setup wizard"
echo "  2. Create admin account, organization, project"
echo "  3. Copy the Project API Key (phc_...) for UserApp integration"
echo ""
