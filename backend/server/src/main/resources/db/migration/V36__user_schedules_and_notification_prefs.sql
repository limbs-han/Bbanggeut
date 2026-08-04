-- 캘린더 일정(기념일)과 알림 설정을 서버로 옮긴다.
-- 일정은 앱 메모리에만 있어 재시작하면 사라졌고(frontend content_state.dart),
-- 알림 토글은 단말 저장 전용이라 서버 푸시가 존중하지 못했다.

-- 일정은 사용자 귀속이다. 캘린더 화면이 금고와 무관하게 한 목록을 쓰므로
-- 금고 귀속으로 넓히는 것은 공유 요구가 생길 때 별도 결정한다.
CREATE TABLE IF NOT EXISTS user_schedules (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title varchar(80) NOT NULL,
    schedule_date date NOT NULL,
    memo varchar(500) NOT NULL DEFAULT '',
    yearly boolean NOT NULL DEFAULT false,
    emoji varchar(16) NOT NULL DEFAULT '❤️',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_user_schedules_title CHECK (char_length(btrim(title)) BETWEEN 1 AND 80)
);

CREATE INDEX IF NOT EXISTS idx_user_schedules_user_date
    ON user_schedules (user_id, schedule_date);

-- 행이 없으면 모두 켜진 것으로 본다(COALESCE(..., true)). 기존 사용자는
-- 행이 없어도 지금처럼 새 영상 푸시를 계속 받는다.
CREATE TABLE IF NOT EXISTS user_notification_preferences (
    user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    anniversary_alerts boolean NOT NULL DEFAULT true,
    weekly_report boolean NOT NULL DEFAULT true,
    new_memory_alerts boolean NOT NULL DEFAULT true,
    updated_at timestamptz NOT NULL DEFAULT now()
);
