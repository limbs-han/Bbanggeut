-- 4컷 만화 1단계(대사 구성) 완료 알림.
--
-- 1단계는 Gemini 호출이라 18초 내외가 걸린다. 응답을 기다리는 동안 사용자가
-- 화면을 벗어나면 대사가 준비된 것을 알 방법이 없었다 — 다시 들어와 직접
-- 확인해야 했다. 2단계(그림)에는 이미 COMIC_READY가 있으므로, 1단계에도
-- 같은 통로를 둔다.
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'COMIC_SCRIPT_READY';
