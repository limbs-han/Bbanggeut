-- 4컷 만화 완성 알림. 그림 생성이 백그라운드로 바뀌어서, 사용자가 화면을
-- 벗어난 뒤에 끝나는 것이 정상 경로가 됐다 — 끝났다고 알려 줄 통로가 필요하다.
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'COMIC_READY';
