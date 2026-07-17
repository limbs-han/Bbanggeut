-- 윌리엄 제임스 핵심 스키마 (관통 경로용 5개 테이블)
-- 기준: 자료/docs/03_ERD_데이터사전.md
-- 이후 추가 예정: invitations, video_edits, access_logs (해당 기능 구현 시)
-- 모든 문은 IF NOT EXISTS → 애플리케이션 재기동에 안전

CREATE TABLE IF NOT EXISTS users (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email           VARCHAR(255) NOT NULL UNIQUE,
    password_hash   VARCHAR(255) NOT NULL,
    display_name    VARCHAR(100) NOT NULL,
    status          VARCHAR(20)  NOT NULL DEFAULT 'ACTIVE'
                    CHECK (status IN ('ACTIVE', 'SUSPENDED', 'DELETED')),
    token_version   INT          NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS devices (
    id                            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    serial_number                 VARCHAR(64)  NOT NULL UNIQUE,
    product_code_hash             CHAR(64)     NOT NULL UNIQUE,   -- SHA-256 hex. 원문 저장 금지
    product_code_retired_at       TIMESTAMPTZ,                    -- 최초 등록 후 재사용 차단
    name                          VARCHAR(100) NOT NULL DEFAULT '카메라',
    model                         VARCHAR(50),
    status                        VARCHAR(20)  NOT NULL DEFAULT 'UNCLAIMED'
                                  CHECK (status IN ('UNCLAIMED', 'ACTIVE', 'DISABLED')),
    retention_days                INT          NOT NULL DEFAULT 30,
    registration_mode_expires_at  TIMESTAMPTZ,                    -- 물리 등록 모드 유효 시각
    claimed_at                    TIMESTAMPTZ,
    claimed_by                    UUID REFERENCES users(id),
    last_seen_at                  TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS device_memberships (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id   UUID        NOT NULL REFERENCES devices(id),
    user_id     UUID        NOT NULL REFERENCES users(id),
    role        VARCHAR(10) NOT NULL CHECK (role IN ('OWNER', 'MEMBER')),
    status      VARCHAR(10) NOT NULL DEFAULT 'ACTIVE'
                CHECK (status IN ('ACTIVE', 'REVOKED')),
    joined_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked_at  TIMESTAMPTZ,
    UNIQUE (device_id, user_id)
);

-- 기기당 활성 OWNER는 정확히 1명 (ERD 원칙 3)
CREATE UNIQUE INDEX IF NOT EXISTS ux_device_active_owner
    ON device_memberships (device_id)
    WHERE role = 'OWNER' AND status = 'ACTIVE';

CREATE TABLE IF NOT EXISTS device_credentials (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id        UUID        NOT NULL REFERENCES devices(id),
    key_id           VARCHAR(64) NOT NULL UNIQUE,
    credential_hash  VARCHAR(255) NOT NULL,                       -- 토큰 해시. 원문 저장 금지
    credential_type  VARCHAR(20) NOT NULL DEFAULT 'TOKEN'
                     CHECK (credential_type IN ('TOKEN', 'CERT')),
    status           VARCHAR(10) NOT NULL DEFAULT 'ACTIVE'
                     CHECK (status IN ('ACTIVE', 'REVOKED')),
    expires_at       TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS videos (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id          UUID         NOT NULL REFERENCES devices(id),
    created_by         UUID REFERENCES users(id),                 -- 기기 자동 생성 시 NULL
    source_type        VARCHAR(20)  NOT NULL DEFAULT 'DEVICE_EVENT'
                       CHECK (source_type IN ('DEVICE_EVENT', 'USER_UPLOAD', 'EDIT_RESULT')),
    trigger_type       VARCHAR(20)
                       CHECK (trigger_type IN ('LAUGH', 'WAKEWORD', 'TOUCH')),
    source_event_id    VARCHAR(64),                               -- 기기 이벤트 멱등 키
    storage_key        VARCHAR(512) NOT NULL UNIQUE,              -- MinIO/S3 객체 키
    size_bytes         BIGINT,
    checksum_sha256    CHAR(64),
    status             VARCHAR(20)  NOT NULL DEFAULT 'UPLOADING'
                       CHECK (status IN ('UPLOADING', 'READY', 'FAILED', 'DELETED')),
    captured_start_at  TIMESTAMPTZ,
    created_at         TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- 같은 기기의 같은 이벤트는 영상 1개 — 업로드 멱등의 핵심 (달성기준 1-2)
CREATE UNIQUE INDEX IF NOT EXISTS ux_video_device_event
    ON videos (device_id, source_event_id)
    WHERE source_event_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_videos_device_created
    ON videos (device_id, created_at DESC);
