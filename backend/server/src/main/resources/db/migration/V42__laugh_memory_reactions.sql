-- 웃음 뽑기 이모지 반응.
--
-- 반응은 "영상 하나 + 가족 구성원 하나"에 하나만 존재한다(UNIQUE). 같은 사람이
-- 다른 이모지를 누르면 새 행을 쌓지 않고 그 행의 reaction_type만 바뀐다 —
-- 반응 취소는 이번 범위가 아니라 삭제 경로는 두지 않는다.
CREATE TABLE IF NOT EXISTS laugh_memory_reactions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    video_id uuid NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
    member_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    reaction_type varchar(20) NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_laugh_memory_reactions_video_member UNIQUE (video_id, member_id),
    CONSTRAINT ck_laugh_memory_reactions_type CHECK (
        reaction_type IN ('FUNNY', 'MISS_THIS', 'GOOD_SAVE', 'EMBARRASSING', 'AGAIN')
    )
);

-- 반응별 개수를 세는 질의가 영상 하나를 기준으로 돌기 때문에.
CREATE INDEX IF NOT EXISTS ix_laugh_memory_reactions_video
    ON laugh_memory_reactions (video_id);

-- 뽑기 후보를 고르는 질의(가족 + 재생 가능 + 최근 캡처)를 위한 부분 인덱스.
CREATE INDEX IF NOT EXISTS ix_videos_laugh_draw_candidates
    ON videos (vault_id, captured_start_at DESC)
    WHERE status = 'READY';
