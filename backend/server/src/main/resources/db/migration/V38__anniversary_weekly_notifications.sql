-- 기념일(일정 D-day)과 주간 웃음 리포트 푸시. 알림 설정(V36)의
-- anniversary_alerts·weekly_report 토글이 저장만 되고 발송기가 없었다.
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'ANNIVERSARY';
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'WEEKLY_REPORT';
