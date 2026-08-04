-- 편집 기능 알림: 서버 분석 완료(요청자에게), 편집 영상 새 댓글(가족에게).
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'EDIT_ANALYSIS_READY';
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'EDIT_COMMENT_ADDED';
