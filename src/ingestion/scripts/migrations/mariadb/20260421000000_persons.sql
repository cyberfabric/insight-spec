-- MariaDB: persons table -- field-level identity attribute history.
-- Stores SCD-like observations: each row = one field value for a person at a point in time.
-- Populated by one-time seed from identity_inputs (ClickHouse view),
-- then maintained by identity resolution pipeline.
--
-- Idempotency: the unique index uq_person_observation guarantees that
-- re-running the seed with the same input produces no duplicates -- an
-- observation is fully identified by
-- (insight_tenant_id, person_id, insight_source_type, insight_source_id,
--  alias_type, alias_value). See ADR-0002 (deterministic person_id).
--
-- Database: analytics (shared with analytics-api for now)
-- Source: docs/domain/identity-resolution/specs/DESIGN.md

CREATE TABLE IF NOT EXISTS persons (
    id                  BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    alias_type          VARCHAR(50)   NOT NULL COMMENT 'Field kind: email, display_name, platform_id, employee_id, etc.',
    insight_source_type VARCHAR(100)  NOT NULL COMMENT 'Source system: bamboohr, zoom, cursor, claude_admin, etc.',
    insight_source_id   CHAR(36)      NOT NULL COMMENT 'Connector instance UUID (sipHash from bronze source_id)',
    insight_tenant_id   CHAR(36)      NOT NULL COMMENT 'Tenant UUID (sipHash from bronze tenant_id)',
    alias_value         VARCHAR(512)  NOT NULL COMMENT 'Field value (email address, display name, platform ID, etc.)',
    person_id           CHAR(36)      NOT NULL COMMENT 'Person UUID -- deterministic UUIDv5 from (insight_tenant_id, lower(trim(email)))',
    author_person_id    CHAR(36)      NOT NULL COMMENT 'Person UUID of who/what made this change',
    reason              TEXT          NOT NULL DEFAULT '' COMMENT 'Optional change reason / comment',
    created_at          DATETIME(3)   NOT NULL DEFAULT CURRENT_TIMESTAMP(3) COMMENT 'When this record was created',

    UNIQUE KEY uq_person_observation (
        insight_tenant_id, person_id, insight_source_type, insight_source_id,
        alias_type, alias_value
    ),
    INDEX idx_person_id (person_id),
    INDEX idx_tenant_person (insight_tenant_id, person_id),
    INDEX idx_alias_lookup (insight_tenant_id, alias_type, alias_value),
    INDEX idx_source (insight_source_type, insight_source_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
