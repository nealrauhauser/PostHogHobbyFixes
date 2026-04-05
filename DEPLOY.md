# PostHog Self-Hosted Deployment

**Date**: 2026-04-01 12:00 UTC
**Status**: RESOLVED — PostHog running at `http://192.168.88.113:8000`

---

## One-Command Deploy

From any machine with SSH access:

```bash
# First: ensure repo is current
ssh repoman@protovm "cd ~/HBbackend && git pull origin pilot"

# Then: run setup (idempotent — safe to re-run)
ssh sounder@protovm "/home/repoman/HBbackend/PostHog/setup.sh"
```

That's it. The script auto-detects `BIND_ADDR` from hostname (protovm → `192.168.88.113`, pilot → `127.0.0.1`), clones PostHog upstream, patches all known ClickHouse/Kafka bugs, generates secrets, starts ~27 containers, and waits for the health check to pass.

**First run** takes ~5 minutes (image pulls + ClickHouse migrations). **Subsequent runs** skip completed steps and just ensure containers are up.

### After First Run Only

Open `http://192.168.88.113:8000` and complete the setup wizard (admin account, organization, project). Copy the **Project API Key** (`phc_...`) into `UserApp/.env` as `POSTHOG_API_KEY`.

---

## Quick Reference

| What | Where |
|------|-------|
| PostHog UI | `http://192.168.88.113:8000` |
| Shell account | `sounder@protovm` |
| PostHog repo | `/home/sounder/posthog/` |
| Patch file | `/home/sounder/posthog/patches/person_sql.py` |
| Health check | `curl http://192.168.88.113:8000/_health` → `ok` |
| Setup script | `/home/repoman/HBbackend/PostHog/setup.sh` (idempotent) |
| Update script | `ssh sounder@protovm "~/update.sh"` (pull + restart) |

### Day-to-Day Commands

```bash
# Update PostHog images and restart
ssh sounder@protovm "~/update.sh"

# Check health
ssh sounder@protovm "curl -s http://192.168.88.113:8000/_health"

# View logs
ssh sounder@protovm "cd ~/posthog && docker compose logs --tail=50 web"

# Restart all containers
ssh sounder@protovm "cd ~/posthog && docker compose restart"

# Full stop / start
ssh sounder@protovm "cd ~/posthog && docker compose down"
ssh sounder@protovm "cd ~/posthog && docker compose up -d"
```

---

## Clean Install Reproduction (Step by Step)

The `setup.sh` script automates all of these steps. This section documents what it does and why, for debugging and manual recovery.

These steps deploy PostHog self-hosted alongside the existing SeenWhole services. The script auto-detects `BIND_ADDR` from hostname. Override with `BIND_ADDR=<ip> ./setup.sh` if needed.

### Prerequisites

- `sounder` shell account exists (member of `docker`, `repomen` groups)
- Docker and Docker Compose installed
- 8+ GB RAM available (protovm has 15 GB)
- Port 5432 already used by healthv10 (PostHog Postgres will use 5433)
- Port 8081 already used by AdminApp (temporal-ui will use 8082)

### Step 1: Clone PostHog and set up directory structure

We do this manually instead of using PostHog's bootstrap script (`bin/deploy-hobby`). The bootstrap runs `apt update`, installs Docker, starts all containers, and waits for a health check — which will timeout because the ClickHouse fixes below haven't been applied yet. The manual approach lets us apply all fixes before the first start.

```bash
ssh protovm   # then: su - sounder
cd ~

# Clone PostHog source
git clone https://github.com/posthog/posthog.git ~/posthog-src --depth 1

# Set up the working directory (same structure the bootstrap creates)
mkdir -p ~/posthog
cd ~/posthog
cp -r ~/posthog-src posthog
cp posthog/docker-compose.base.yml docker-compose.base.yml
cp posthog/docker-compose.hobby.yml docker-compose.hobby.yml

# Create dev-services.env — base.yml references this for container-internal
# connection strings. All hostnames are Docker-internal (db, clickhouse, etc.)
cp posthog/dev-services.env dev-services.env
# If upstream doesn't ship it, setup.sh generates one with the correct values.
```

### Step 2: Fix port conflicts in PostHog compose files

PostHog's defaults conflict with SeenWhole services. Edit these files:

**`docker-compose.hobby.yml`** — bind all ports to LAN IP, remap Caddy:
```bash
cd ~/posthog

# Caddy proxy: 80 → 8000 (port 80 is UserApp)
# NOTE: PostHog compose uses single quotes for port mappings
sed -i "s/'80:80'/'192.168.88.113:8000:80'/" docker-compose.hobby.yml
sed -i "s/'443:443'/'192.168.88.113:8443:443'/" docker-compose.hobby.yml

# Temporal: bind to LAN IP (no quotes in original)
sed -i 's/7233:7233/192.168.88.113:7233:7233/' docker-compose.hobby.yml

# Object storage: bind to LAN IP
sed -i "s/'19000:19000'/'192.168.88.113:19000:19000'/" docker-compose.hobby.yml
sed -i "s/'19001:19001'/'192.168.88.113:19001:19001'/" docker-compose.hobby.yml
```

**`docker-compose.hobby.yml`** — temporal-ui port (8081 → 8082, conflicts with AdminApp):
```bash
sed -i 's|.*8081:8080.*|            - 127.0.0.1:8082:8080|' docker-compose.hobby.yml
```

### Step 3: Fix compose entrypoint scripts

The hobby compose mounts `./compose:/compose` and calls these scripts as entrypoints. The bootstrap (`bin/deploy-hobby`) generates them, but since we skip the bootstrap, we create them manually:

```bash
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
```

And `compose/wait` (waits for ClickHouse + Postgres before any service starts):

```bash
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
```

### Step 4: Fix ClickHouse projection mode (Issue 1)

ClickHouse 24.8+ changed `deduplicate_merge_projection_mode` default from `drop` to `throw`. PostHog's migrations create projections on ReplacingMergeTree tables, which now fails. No upstream fix exists.

The config file `posthog/docker/clickhouse/config.d/default.xml` is bind-mounted into the container. Add the `<merge_tree>` block **before** the closing `</clickhouse>` tag:

```bash
sed -i 's|</clickhouse>|    <merge_tree>\n        <deduplicate_merge_projection_mode>drop</deduplicate_merge_projection_mode>\n        <lightweight_mutation_projection_mode>drop</lightweight_mutation_projection_mode>\n    </merge_tree>\n</clickhouse>|' posthog/docker/clickhouse/config.d/default.xml
```

**Verify** the closing of the file looks like:
```xml
    <merge_tree>
        <deduplicate_merge_projection_mode>drop</deduplicate_merge_projection_mode>
        <lightweight_mutation_projection_mode>drop</lightweight_mutation_projection_mode>
    </merge_tree>
</clickhouse>
```

**Why the previous attempt failed**: A separate `posthog-compat.xml` was placed in the host's `config.d/` directory, but PostHog's hobby compose mounts individual files (`config.d/default.xml`), not the directory. Extra files are invisible inside the container.

### Step 5: Patch Kafka table SQL (Issue 2)

PostHog's `posthog/models/person/sql.py` has `DEFAULT` clauses in SQL templates shared between MergeTree tables (where DEFAULT is fine) and Kafka tables (where it's banned since ClickHouse 23.3). This is [PostHog bug #15625](https://github.com/PostHog/posthog/issues/15625) — open since May 2023, unresolved.

Extract the file from the image (no running container needed), then patch:

```bash
# Pull the image and extract the file without starting anything
docker pull posthog/posthog:latest-release
docker create --name posthog-extract posthog/posthog:latest-release
mkdir -p patches
docker cp posthog-extract:/code/posthog/models/person/sql.py patches/person_sql.py
docker rm posthog-extract

# Patch: remove DEFAULT clauses that break Kafka engine tables
sed -i 's/is_deleted Int8 DEFAULT 0/is_deleted Int8/' patches/person_sql.py
sed -i 's/version Int64 DEFAULT 1/version Int64/' patches/person_sql.py
```

**Why this is safe**: ClickHouse integer columns default to `0` implicitly, and `version` is always explicitly set on insert by PostHog's application code.

### Step 6: Create `.env`

Generate secrets and create the entire `.env` from scratch:

```bash
# Generate secrets
POSTHOG_SECRET=$(head -c 28 /dev/urandom | sha224sum | head -c 56)
FERNET_KEY=$(python3 -c "import base64, os; print(base64.urlsafe_b64encode(os.urandom(24)).decode())")
echo "POSTHOG_SECRET: $POSTHOG_SECRET"
echo "FERNET_KEY: $FERNET_KEY (32 chars)"

cat > .env << ENVEOF
POSTHOG_SECRET=$POSTHOG_SECRET
ENCRYPTION_SALT_KEYS=$FERNET_KEY
SITE_URL=http://192.168.88.113:8000
DOMAIN=192.168.88.113
WEB_HOSTNAME=192.168.88.113
REGISTRY_URL=posthog/posthog
POSTHOG_APP_TAG=latest-release
COMPOSE_FILE=docker-compose.hobby.yml:docker-compose.override.yml
CLICKHOUSE_SERVER_IMAGE=clickhouse/clickhouse-server:25.12.5.44
CADDY_HOST=http://:80
SKIP_SERVICE_VERSION_REQUIREMENTS=1
IS_BEHIND_PROXY=false
ENVEOF
```

**Why each setting matters**:
- `POSTHOG_SECRET`: Django secret key for session signing. Generated randomly.
- `ENCRYPTION_SALT_KEYS`: 32-character base64url Fernet key (24 random bytes). The plugins Node.js service validates this format strictly — hex strings or wrong-length keys cause a crash.
- `COMPOSE_FILE`: Using `-f docker-compose.hobby.yml` disables auto-loading of override files. This ensures both files are always loaded.
- `CLICKHOUSE_SERVER_IMAGE`: Pins ClickHouse to the version PostHog expects (the base compose default is the same, but being explicit avoids surprises).
- `CADDY_HOST`: The base compose defaults to `http://localhost:8000` which only binds to localhost inside the container. Setting `http://:80` binds to all interfaces on port 80, matching the `8000:80` Docker port mapping.
- `SKIP_SERVICE_VERSION_REQUIREMENTS`: PostHog's bundled Postgres is 15.x but PostHog warns about anything above 14.1. This suppresses the fatal version check.
- `IS_BEHIND_PROXY`: Set to `false` for direct LAN access on protovm.

### Step 7: Create `docker-compose.override.yml`

This file provides memory limits, the SQL patch mount, and env vars the hobby compose doesn't pass:

Run this in the same shell session as Step 6 (so `$FERNET_KEY` is still set):

```bash
cat > docker-compose.override.yml << YAMLEOF
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
      - "192.168.88.113:5433:5432"

  web:
    volumes:
      - ./patches/person_sql.py:/code/posthog/models/person/sql.py
    environment:
      SKIP_SERVICE_VERSION_REQUIREMENTS: "1"
      IS_BEHIND_PROXY: "false"

  worker:
    volumes:
      - ./patches/person_sql.py:/code/posthog/models/person/sql.py
    environment:
      SKIP_SERVICE_VERSION_REQUIREMENTS: "1"

  plugins:
    environment:
      SKIP_SERVICE_VERSION_REQUIREMENTS: "1"
      ENCRYPTION_SALT_KEYS: "$FERNET_KEY"

  asyncmigrationscheck:
    environment:
      SKIP_SERVICE_VERSION_REQUIREMENTS: "1"

  cymbal:
    environment:
      SKIP_SERVICE_VERSION_REQUIREMENTS: "1"

  feature-flags:
    environment:
      SKIP_SERVICE_VERSION_REQUIREMENTS: "1"

  temporal-django-worker:
    volumes:
      - ./patches/person_sql.py:/code/posthog/models/person/sql.py
    environment:
      SKIP_SERVICE_VERSION_REQUIREMENTS: "1"
YAMLEOF
```

### Step 8: Start PostHog

```bash
docker compose up -d
```

Because `COMPOSE_FILE` is set in `.env`, this loads both the hobby and override files automatically.

### Step 9: Verify

Wait ~2 minutes for ClickHouse migrations (37 migrations on first boot), then:

```bash
# Health check
curl http://192.168.88.113:8000/_health
# Expected: ok

# Check container status
docker compose ps
# Expected: web, worker, plugins, proxy all "Up"
# Known cycling: feature-flags, cymbal (missing GeoLite2 DB — see below)

# Check ClickHouse migrations completed
docker logs posthog-web-1 2>&1 | grep -E '(Applying migration|gunicorn|Listening)'
# Expected: 37 "Applying migration" lines followed by "Listening at: http://0.0.0.0:8000"
```

### Step 10: Complete setup wizard

Open `http://192.168.88.113:8000` in a browser. Create admin account, organization, and project. Copy the **Project API Key** (starts with `phc_`) for UserApp integration.

### Step 11: Create update.sh

```bash
cat > ~/update.sh << 'EOF'
#!/bin/bash
set -e
cd ~/posthog
docker compose pull
docker compose up -d
echo "PostHog updated and restarted"
EOF
chmod +x ~/update.sh
```

### Step 12: Enable auto-start on boot

Create a systemd service so PostHog starts automatically after a reboot. The 30-second delay ensures Docker networking is fully ready before containers start (without this, Rust services fail DNS resolution and crash-loop).

Run as root:
```bash
cat > /etc/systemd/system/posthog.service << 'EOF'
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
EOF
systemctl daemon-reload
systemctl enable posthog.service
```

After this, PostHog will start automatically on boot. Manual control:
```bash
systemctl start posthog    # start
systemctl stop posthog     # stop
systemctl status posthog   # check
```

---

## Known Non-Critical Issues

### feature-flags + cymbal (RESOLVED — GeoLite2 installed)

Both Rust services crash on missing `/share/GeoLite2-City.mmdb`. Fixed by downloading the free GeoLite2 database and mounting it into both containers.

```bash
mkdir -p ~/posthog/share
curl -sL https://github.com/P3TERX/GeoLite.mmdb/releases/latest/download/GeoLite2-City.mmdb \
  -o ~/posthog/share/GeoLite2-City.mmdb
```

Then add volumes to both services in `docker-compose.override.yml`:
```yaml
  cymbal:
    volumes:
      - ./share:/share

  feature-flags:
    volumes:
      - ./share:/share
```

To update the database periodically, re-run the `curl` command — the file is bind-mounted so a container restart picks up the new version.

### temporal (port 7233)

If Docker's port proxy doesn't release port 7233 after a failed container start, run `systemctl restart docker` on protovm (this restarts all containers). Temporal handles async workflows (exports, batch operations) — not needed for core analytics.

---

## Issue Details

### Issue 1: ClickHouse Projection Mode

**Error**: `Code: 344. DB::Exception: Projections are not supported for ReplacingMergeTree with deduplicate_merge_projection_mode = throw`

**Root cause**: ClickHouse 24.8+ changed the default from `drop` to `throw` ([PR #66672](https://github.com/ClickHouse/ClickHouse/pull/66672)). PostHog creates projections on ReplacingMergeTree tables during migration.

**Fix**: `<merge_tree>` config in `default.xml` (Step 4). GitLab hit the same issue and fixed it the same way ([GDK MR !3991](https://gitlab.com/gitlab-org/gitlab-development-kit/-/merge_requests/3991)).

**What didn't work and why**:
| Approach | Why It Failed |
|----------|--------------|
| Separate `posthog-compat.xml` in `config.d/` | Not mounted — hobby compose mounts individual files, not directories |
| Profile-level setting in `users.xml` | ClickHouse crashes — this is a MergeTree setting, not a user setting |
| Downgrade to ClickHouse 25.8.12 | 25.8 also defaults to `throw`; also caused Kafka DEFAULT issue (Issue 2) |

### Issue 2: KafkaEngine DEFAULT Columns

**Error**: `Code: 36. DB::Exception: KafkaEngine doesn't support DEFAULT/MATERIALIZED/EPHEMERAL expressions for columns`

**Root cause**: `posthog/models/person/sql.py` shares base SQL templates between MergeTree and Kafka engine tables. Two templates have `DEFAULT` clauses (`is_deleted Int8 DEFAULT 0`, `version Int64 DEFAULT 1`). Kafka engine has banned DEFAULT since ClickHouse 23.3 ([PR #47138](https://github.com/ClickHouse/ClickHouse/pull/47138)). Five migrations (0004, 0009, 0013, 0014, 0029) call the affected SQL functions.

**Fix**: Patched `person_sql.py` mounted via Docker volume (Step 5). This is [PostHog #15625](https://github.com/PostHog/posthog/issues/15625).

**Why `infi.clickhouse_orm` makes this worse**: The migration runner records a migration as "applied" even when individual operations within it fail. This creates a state where the migration registry is ahead of reality, requiring a full data wipe to recover.

### Issue 3: Caddy Proxy Binding

**Root cause**: Base compose sets `CADDY_HOST: 'http://localhost:8000'`. The `CADDYFILE` template uses `${CADDY_HOST}` which resolves at compose-parse time from the base's default, not from runtime env. Hobby compose's override of `CADDY_HOST` only takes effect at container runtime — too late for the template.

**Fix**: Set `CADDY_HOST=http://:80` in `.env` which is read at compose-parse time (Step 6).

### Issue 4: Plugins Fernet Key

**Root cause**: The plugins service (Node.js) requires `ENCRYPTION_SALT_KEYS` to be a 32-character base64url string (24 random bytes). The bootstrap script generates a random string that doesn't match this format. Additionally, the hobby compose doesn't pass `ENCRYPTION_SALT_KEYS` to the plugins container — it must be set explicitly in the override.

**Fix**: Generate a proper key and set it in both `.env` (Step 6) and the override (Step 7).

### Issue 5: Override File Not Loading

**Root cause**: `docker compose -f docker-compose.hobby.yml` disables auto-loading of `docker-compose.override.yml`. All override settings (memory limits, env vars, volume mounts) are silently ignored.

**Fix**: `COMPOSE_FILE=docker-compose.hobby.yml:docker-compose.override.yml` in `.env` (Step 6).

---

## Files Modified on protovm

All files are under `/home/sounder/posthog/`:

| File | Change | Source |
|------|--------|--------|
| `posthog/docker/clickhouse/config.d/default.xml` | Added `<merge_tree>` block before `</clickhouse>` | Step 4 |
| `patches/person_sql.py` | Removed `DEFAULT 0` and `DEFAULT 1` from shared SQL templates | Step 5 |
| `docker-compose.override.yml` | Volume mounts, env vars, memory limits, DB port remap | Step 7 |
| `.env` | All settings: secrets, COMPOSE_FILE, CADDY_HOST, CLICKHOUSE_SERVER_IMAGE, SKIP vars | Step 6 |
| `docker-compose.hobby.yml` | Ports bound to `192.168.88.113`, Caddy 80→8000, 443→8443 | Step 2 |
| `docker-compose.base.yml` | temporal-ui port 8081→8082 | Step 2 |
| `compose/start` | Fixed `./compose/wait` → `/compose/wait` (absolute path) | Step 3 |
| `compose/temporal-django-worker` | Entrypoint for temporal worker container | Step 3 |
| `compose/wait` | Python wait script (generated, matches bootstrap) | Step 3 |
| `dev-services.env` | Container-internal connection strings + Redis host overrides | Step 1 |

---

## Issue Details

### Issue 6: Node Services Redis Crash Loop

**Error**: `😡 [recording-api] Redis error encountered! host: 127.0.0.1:6379 Enough of this, I quit!`

**Affected containers**: `posthog-plugins-1`, and all `posthog-ingestion-*` containers.

**Root cause**: PostHog's Node config system (`config/config.js`) merges sub-configs via JavaScript spread. Each sub-service defines its own Redis env var defaulting to `127.0.0.1`:

| Config file | Env var | Default |
|-------------|---------|---------|
| `common/config.js` | `REDIS_URL` | `redis://127.0.0.1` |
| `cdp/config.js` | `CDP_REDIS_HOST` | `127.0.0.1` |
| `logs-ingestion/config.js` | `LOGS_REDIS_HOST` | `127.0.0.1` |
| `logs-ingestion/config.js` | `TRACES_REDIS_HOST` | `127.0.0.1` |
| `session-recording/config.js` | `SESSION_RECORDING_API_REDIS_HOST` | `127.0.0.1` |

The `overrideWithEnv()` function replaces these defaults from `process.env`, but only if the env var is present. Setting just `REDIS_URL` is insufficient — the sub-service vars still default to `127.0.0.1`.

**Fix**: All five vars are set in `dev-services.env` (Step 1), which is loaded via `env_file:` in the Docker Compose override. The `plugins` service gets `env_file: dev-services.env` explicitly in the override.

**What didn't work and why**:
| Approach | Why It Failed |
|----------|--------------|
| Setting only `REDIS_URL=redis://redis7:6379/` | Sub-service configs define their own `*_REDIS_HOST` vars that aren't derived from `REDIS_URL` |
| Adding `LOGS_REDIS_HOST` and `TRACES_REDIS_HOST` to override environment | Missing `CDP_REDIS_HOST` and `SESSION_RECORDING_API_REDIS_HOST` — all four must be set |
| Adding `env_file: dev-services.env` to plugins without the Redis host vars | `dev-services.env` only had `REDIS_URL`, not the per-service host vars |

**How to discover new Redis vars if PostHog adds more sub-services**:
```bash
docker compose run --rm plugins grep -rn '127\.0\.0\.1' /code/nodejs/dist --include='config.js'
```
