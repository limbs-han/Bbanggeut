-- 편집 완성본과 댓글을 백엔드(시스템 오브 레코드)로 편입한다.
--
-- 지금까지 완성본 MP4·메타·댓글은 editor-api가 MinIO JSON으로 들고 있었다.
-- 그 결과 (1) 권한을 매 요청 백엔드에 되물어야 했고, (2) 보관 만료가 아예
-- 없어 편집본이 영구 보존됐고, (3) 댓글이 read-modify-write라 동시 작성이
-- 유실됐고, (4) 작성자 표시 이름이 앱 자가 신고라 위조 가능했다.
-- videos 행으로 편입하면 권한·보관·삭제·알림이 원본 영상과 같은 경로를 탄다.
--
-- source_type 'EDIT_OUTPUT'은 V4 enum에 이미 있다(서버 편집 시절의 값).

ALTER TABLE videos
    ADD COLUMN IF NOT EXISTS source_video_id uuid REFERENCES videos(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS ix_videos_source_video
    ON videos (source_video_id)
    WHERE source_video_id IS NOT NULL;

-- 금고별 편집본 목록(최신순).
CREATE INDEX IF NOT EXISTS ix_videos_edit_outputs
    ON videos (vault_id, created_at DESC)
    WHERE source_type = 'EDIT_OUTPUT';

-- 완성본은 OS 백그라운드 작업(WorkManager)이 세션 없이 올린다. /complete를
-- 부를 주체가 없으므로 서버가 객체 도착을 훑어 READY로 승격한다.
CREATE INDEX IF NOT EXISTS ix_videos_pending_edit_upload
    ON videos (updated_at, id)
    WHERE status = 'UPLOADING' AND source_type = 'EDIT_OUTPUT';

CREATE TABLE IF NOT EXISTS video_comments (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    video_id uuid NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
    author_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    body varchar(500) NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_video_comments_body CHECK (char_length(btrim(body)) BETWEEN 1 AND 500)
);

CREATE INDEX IF NOT EXISTS ix_video_comments_video
    ON video_comments (video_id, created_at, id);
