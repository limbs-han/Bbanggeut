-- 양방향 오디오(talkback)는 앱이 기기 스피커로 말하는 역방향 경로다.
-- 기기에는 에코 제거가 없어 두 명이 동시에 말하면 서로의 뮤트가 상대의 에코
-- 순환을 끊어주지 못한다.
-- device_id를 기본 키로 두어 "발화 권한" 자체가 행 하나가 되게 하고,
-- 권한 획득을 ON CONFLICT ... WHERE 한 번으로 원자적으로 처리한다.
ALTER TYPE audit_action ADD VALUE IF NOT EXISTS 'TALKBACK_OPEN';
ALTER TYPE audit_action ADD VALUE IF NOT EXISTS 'TALKBACK_CLOSE';

CREATE TABLE IF NOT EXISTS device_talkbacks (
    device_id uuid PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
    session_id uuid NOT NULL REFERENCES stream_sessions(id) ON DELETE CASCADE,
    stream_id uuid NOT NULL REFERENCES device_streams(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- 만료된 발화 권한을 회수하는 워커가 매 5초 스캔한다.
CREATE INDEX IF NOT EXISTS idx_device_talkbacks_expires_at
    ON device_talkbacks (expires_at);
