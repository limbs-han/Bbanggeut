-- 4컷 만화(API-71·API-72)는 원본 영상과 기기에서 만든 전사문을 외부 생성 모델로
-- 보낸다. 누가 어느 영상으로 만화를 만들었는지 남겨야 하므로 감사 동작을 추가한다.
ALTER TYPE audit_action ADD VALUE IF NOT EXISTS 'COMIC_SCRIPT';
ALTER TYPE audit_action ADD VALUE IF NOT EXISTS 'COMIC_IMAGE';
