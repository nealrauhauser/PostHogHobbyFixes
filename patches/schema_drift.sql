-- PostHog Schema Drift Fixes
-- 2026-04-07T07:00:00Z
--
-- The PostHog hobby deploy ships a Node image (plugins, ingestion) that
-- expects tables and columns not created by the bundled Django migrations.
-- This file is the single source of truth for all schema drift fixes.
-- All statements are idempotent (IF NOT EXISTS / IF NOT EXISTS).
--
-- Used by: setup.sh (Step 11), update.sh, and manual remediation.

-- ═══════════════════════════════════════════════════════════════════════
-- Missing columns on existing Django-managed tables
-- ═══════════════════════════════════════════════════════════════════════

ALTER TABLE posthog_team ADD COLUMN IF NOT EXISTS project_id BIGINT;
ALTER TABLE posthog_team ADD COLUMN IF NOT EXISTS secret_api_token VARCHAR(48);
ALTER TABLE posthog_team ADD COLUMN IF NOT EXISTS person_processing_opt_out BOOLEAN DEFAULT NULL;
ALTER TABLE posthog_team ADD COLUMN IF NOT EXISTS heatmaps_opt_in BOOLEAN DEFAULT NULL;
ALTER TABLE posthog_team ADD COLUMN IF NOT EXISTS cookieless_server_hash_mode SMALLINT DEFAULT NULL;
ALTER TABLE posthog_team ADD COLUMN IF NOT EXISTS logs_settings JSONB DEFAULT NULL;
ALTER TABLE posthog_team ADD COLUMN IF NOT EXISTS extra_settings JSONB DEFAULT NULL;
ALTER TABLE posthog_team ADD COLUMN IF NOT EXISTS drop_events_older_than INTERVAL DEFAULT NULL;
ALTER TABLE posthog_organization ADD COLUMN IF NOT EXISTS available_product_features JSONB DEFAULT '[]'::jsonb;
ALTER TABLE posthog_grouptypemapping ADD COLUMN IF NOT EXISTS project_id BIGINT;
ALTER TABLE posthog_eventdefinition ADD COLUMN IF NOT EXISTS enforcement_mode VARCHAR(24) DEFAULT NULL;
ALTER TABLE posthog_person ADD COLUMN IF NOT EXISTS last_seen_at TIMESTAMPTZ DEFAULT NULL;

-- ═══════════════════════════════════════════════════════════════════════
-- Event schema enforcement tables (ingestion-general crash-loops without these)
-- ═══════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS posthog_eventdefinition (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id INTEGER NOT NULL,
    name VARCHAR(400) NOT NULL,
    enforcement_mode VARCHAR(24) DEFAULT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    last_seen_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS posthog_eventschema (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id INTEGER NOT NULL,
    event VARCHAR(400) NOT NULL,
    event_definition_id UUID DEFAULT NULL,
    property_group_id UUID DEFAULT NULL,
    schema JSONB DEFAULT '{}'::jsonb,
    last_seen_at TIMESTAMPTZ DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW()
);
ALTER TABLE posthog_eventschema ADD COLUMN IF NOT EXISTS event_definition_id UUID DEFAULT NULL;
ALTER TABLE posthog_eventschema ADD COLUMN IF NOT EXISTS property_group_id UUID DEFAULT NULL;
CREATE INDEX IF NOT EXISTS idx_eventschema_team_event ON posthog_eventschema(team_id, event);

CREATE TABLE IF NOT EXISTS posthog_schemapropertygroupproperty (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    property_group_id UUID NOT NULL,
    name VARCHAR(400) NOT NULL,
    property_type VARCHAR(50) DEFAULT NULL,
    is_required BOOLEAN DEFAULT false
);
CREATE INDEX IF NOT EXISTS idx_schemaprop_group ON posthog_schemapropertygroupproperty(property_group_id);

-- ═══════════════════════════════════════════════════════════════════════
-- CDP / HogFunction tables (queried on every event by ingestion-general)
-- ═══════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS posthog_hogfunction (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id INTEGER NOT NULL,
    name VARCHAR(400) DEFAULT '',
    enabled BOOLEAN DEFAULT false,
    deleted BOOLEAN DEFAULT false,
    inputs JSONB DEFAULT '{}',
    encrypted_inputs JSONB DEFAULT NULL,
    inputs_schema JSONB DEFAULT '[]',
    filters JSONB DEFAULT NULL,
    mappings JSONB DEFAULT NULL,
    bytecode JSONB DEFAULT NULL,
    masking JSONB DEFAULT NULL,
    type VARCHAR(24) DEFAULT '',
    template_id VARCHAR(400) DEFAULT NULL,
    execution_order INTEGER DEFAULT 0,
    batch_export_id UUID DEFAULT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS posthog_hogflow (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id INTEGER NOT NULL,
    name VARCHAR(400) DEFAULT '',
    description TEXT DEFAULT '',
    version INTEGER DEFAULT 1,
    status VARCHAR(24) DEFAULT 'draft',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    trigger JSONB DEFAULT NULL,
    trigger_masking JSONB DEFAULT NULL,
    conversion JSONB DEFAULT NULL,
    exit_condition JSONB DEFAULT NULL,
    edges JSONB DEFAULT '[]',
    actions JSONB DEFAULT '[]',
    abort_action JSONB DEFAULT NULL,
    billable_action_types JSONB DEFAULT '[]'
);

CREATE TABLE IF NOT EXISTS posthog_hogfunctiontemplate (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    template_id VARCHAR(400) NOT NULL,
    team_id INTEGER DEFAULT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ═══════════════════════════════════════════════════════════════════════
-- Person processing tables
-- ═══════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS posthog_personlessdistinctid (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id INTEGER NOT NULL,
    distinct_id VARCHAR(400) NOT NULL,
    is_merged BOOLEAN DEFAULT false
);
CREATE INDEX IF NOT EXISTS idx_personlessdistinctid_team_distinct ON posthog_personlessdistinctid(team_id, distinct_id);

CREATE TABLE IF NOT EXISTS posthog_flatpersonoverride (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id INTEGER NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS posthog_pendingpersonoverride (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id INTEGER NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS posthog_personoverride (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id INTEGER NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS posthog_personoverridemapping (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id INTEGER NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ═══════════════════════════════════════════════════════════════════════
-- Project / misc tables
-- ═══════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS posthog_project (
    id BIGSERIAL PRIMARY KEY,
    organization_id UUID NOT NULL,
    name VARCHAR(400) DEFAULT '',
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS posthog_comment (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id INTEGER NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS posthog_exportedrecording (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id INTEGER NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS posthog_messagerecipientpreference (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id INTEGER NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
