-- 4컷 만화를 제 행으로 세운다 — 제목·좋아요·댓글이 붙을 자리가 필요해서다.
--
-- **왜 알림 행으로는 안 되는가**: 지금까지 "이 금고에 어떤 만화가 있는가"를
-- COMIC_READY 알림으로 갈음했다(V43). 배지 하나를 그리는 데는 충분했지만,
-- 만화에 제목을 달고 좋아요와 댓글을 붙이려면 그것들이 참조할 행이 있어야
-- 한다. 알림은 사람마다 생기고 읽음 처리로 지워질 수 있는 것이라 기준이 될 수
-- 없다.
--
-- 만화는 영상 하나에 하나다(워커가 `comic/{video_id}/panel.png` 한 자리에
-- 덮어쓴다). 그래서 video_id가 그대로 PK다 — 대리 키를 두면 "같은 영상에 만화
-- 둘"이 표현 가능해져서, 실제로는 불가능한 상태를 코드가 방어해야 한다.
CREATE TABLE IF NOT EXISTS comics (
    video_id uuid PRIMARY KEY REFERENCES videos(id) ON DELETE CASCADE,
    -- 비었으면 원본 영상 제목을 그대로 보여 준다. 사용자가 고친 때만 채운다 —
    -- 원본 제목을 복사해 두면 원본을 고쳐도 만화 제목이 옛 이름으로 남는다.
    title varchar(200),
    made_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- 금고 피드는 "이 금고의 만화를 최신순"으로 읽는다. video_id만으로는 금고를
-- 알 수 없어 videos와 조인하므로, videos(vault_id) 쪽 인덱스에 의존한다.
CREATE INDEX IF NOT EXISTS ix_comics_made_at ON comics (made_at DESC);

-- 이미 만들어 둔 만화를 옮겨 온다. 이 백필이 없으면 지금까지 만든 만화가
-- 피드에서 통째로 사라진다 — 사용자에게는 데이터가 없어진 것으로 보인다.
INSERT INTO comics (video_id, made_at)
SELECT n.resource_id, MIN(n.created_at)
  FROM notifications n
 WHERE n.type = 'COMIC_READY'
   AND n.resource_id IS NOT NULL
   AND EXISTS (SELECT 1 FROM videos v WHERE v.id = n.resource_id)
 GROUP BY n.resource_id
ON CONFLICT (video_id) DO NOTHING;

-- 좋아요는 "만화 하나 + 사람 하나"에 하나다. 두 컬럼이 곧 PK라서 같은 사람이
-- 두 번 눌러도 행이 쌓이지 않고, 취소는 DELETE 한 번이다.
CREATE TABLE IF NOT EXISTS comic_likes (
    video_id uuid NOT NULL REFERENCES comics(video_id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (video_id, user_id)
);

-- 개수를 세는 질의가 만화 하나를 기준으로 돈다. PK가 (video_id, user_id)라
-- 앞선 컬럼만으로도 훑을 수 있어 별도 인덱스를 두지 않는다.

-- 만화 댓글. 영상 댓글(video_comments)과 나누는 이유: 만화에 단 말과 영상에 단
-- 말은 가리키는 대상이 다르다. 한 스레드로 합치면 만화 피드에 영상 얘기가
-- 섞이고, 영상 상세에 만화 얘기가 섞인다.
CREATE TABLE IF NOT EXISTS comic_comments (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    video_id uuid NOT NULL REFERENCES comics(video_id) ON DELETE CASCADE,
    author_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    body text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- 만화 하나의 댓글을 시간순으로 읽는다.
CREATE INDEX IF NOT EXISTS ix_comic_comments_video
    ON comic_comments (video_id, created_at);
