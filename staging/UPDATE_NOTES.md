# PostHogHobbyFixes Update Notes
## 2026-04-07T07:30:00Z

Files in this staging/ dir are from HBbackend/PostHog/ — ready to adapt for the public repo.

## New Issues to Document

### Issue 12: SESSION_RECORDING_V2_S3_* defaults to localhost:8333
- Plugin server session recording config has 6 vars defaulting to localhost:8333 with dummy creds
- Vars: SESSION_RECORDING_V2_S3_ENDPOINT, _BUCKET, _PREFIX, _REGION, _ACCESS_KEY_ID, _SECRET_ACCESS_KEY
- Fix: Override all 6 in dev-services.env pointing to objectstorage:19000

### Issue 13: Event Schema Enforcement Tables Missing
- posthog_eventschema (needs event_definition_id + property_group_id columns)
- posthog_eventdefinition (needs enforcement_mode column — Django creates table without it)
- posthog_schemapropertygroupproperty (entirely missing)
- Ingestion-general crash-loops without these

### Issue 14: 12 Missing Tables (Node/Django schema mismatch)
- Django migrations are behind the Node image code
- manage.py migrate says "nothing to apply" but Node queries tables that don't exist
- Full list: posthog_hogfunction (20 cols), posthog_hogflow (16 cols), posthog_hogfunctiontemplate, posthog_personlessdistinctid, posthog_project, posthog_comment, posthog_exportedrecording, posthog_flatpersonoverride, posthog_pendingpersonoverride, posthog_personoverride, posthog_personoverridemapping, posthog_messagerecipientpreference
- Fix: patches/schema_drift.sql — run after every install/update

### Issue 15: posthog_person.last_seen_at Missing
- Node ingestion fetchPerson query selects last_seen_at which Django didn't create
- Fix: ALTER TABLE posthog_person ADD COLUMN IF NOT EXISTS last_seen_at TIMESTAMPTZ DEFAULT NULL

### Issue 16: Heartbeat Sidecar $$ Escaping Bug
- In unquoted heredoc, $$ is bash PID (e.g. "1026601"), not literal $
- Redis key was "1026601(date-u+%Y...)" instead of a timestamp
- Fix: Use \$\$ in the heredoc so YAML gets $$, Compose renders $, shell evaluates $(date)

### Issue (minor): Missing Postgres/Temporal/Site vars
- POSTHOG_POSTGRES_HOST, POSTGRES_BEHAVIORAL_COHORTS_HOST, TEMPORAL_HOST, SITE_URL, POSTHOG_HOST_URL
- Not in dev-services.env, default to localhost inside containers

## Smoke Test Improvements
- Detects "not installed" (< 5 containers) and exits early
- Remediation block prints specific fix commands per failure category
- Optional services (CDP email, Cymbal, OTEL, SES) demoted to warnings
- Version drift detection widened to catch any localhost default (not just *_REDIS_HOST)
- posthog_eventschema table check added

## TODO: Report Submission Feature
- Add --report flag to smoke_test.sh
- Output machine-readable results (JSON) for filing issues or sharing
