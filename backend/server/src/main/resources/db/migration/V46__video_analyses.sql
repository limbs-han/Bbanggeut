-- 영상 분석이 "지금 어디까지 왔는가"를 백엔드가 알게 한다.
--
-- **왜 지금까지 몰랐나**: 분석 결과(yamnet·audio·video·expression JSON)는 워커가
-- MinIO에 남기고, 진행 상태는 워커 프로세스의 메모리 dict에만 있었다. 그래서
--   1. 워커를 재배포하면 "분석 중"이던 영상이 "분석한 적 없음"으로 보였고,
--   2. 앱이 상태를 알려면 백엔드를 지나 워커까지 물어야 했으며,
--   3. 백엔드는 어느 영상이 분석됐는지 몰라 목록에 표시를 달 수 없었다.
--
-- **왜 결과 JSON은 여기 넣지 않나**: 실측(검증 영상 5개, 2분 내외) 한 영상당
-- expression 336KB · video 149KB · yamnet 123KB · audio 86KB — 합계 약 700KB다.
-- 행 하나가 8KB 페이지를 훨씬 넘어 전부 TOAST로 빠지고, 읽을 때마다 압축을
-- 풀어야 하며, 백업과 복제본이 영상 1,000개에 700MB씩 불어난다. 큰 덩어리는
-- 객체 저장소가 맞다. DB에는 **상태만** 둔다 — 작고, 자주 읽고, 조인이 필요한 값.
CREATE TABLE IF NOT EXISTS video_analyses (
    -- 영상 하나에 분석 하나다. 다시 돌리면 같은 행을 덮는다.
    video_id uuid PRIMARY KEY REFERENCES videos(id) ON DELETE CASCADE,
    -- RUNNING | DONE | FAILED. 행이 없으면 '분석한 적 없음'이다 — NONE을 값으로
    -- 두면 "행이 없다"와 "NONE이다"라는 같은 뜻의 상태가 둘이 된다.
    status varchar(16) NOT NULL,
    -- download | audio | yamnet | video | expression. 어디까지 왔는지 사람에게
    -- 보여 줄 값이라 워커의 단계 이름을 그대로 쓴다.
    stage varchar(32),
    -- 0.0~1.0. 워커가 단계마다 올린다.
    progress real NOT NULL DEFAULT 0,
    error text,
    -- 분석을 청한 사람. 완료 알림의 수신자이자 "누가 걸어 둔 분석인가"다.
    requested_by uuid REFERENCES users(id) ON DELETE SET NULL,
    started_at timestamptz NOT NULL DEFAULT now(),
    finished_at timestamptz,
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- 오래 걸린 분석을 찾거나(멈춘 작업 청소) 최근 것부터 보려는 질의를 위한 것.
CREATE INDEX IF NOT EXISTS ix_video_analyses_running
    ON video_analyses (started_at DESC)
 WHERE status = 'RUNNING';

-- 이미 분석해 둔 영상을 옮겨 온다. 워커 MinIO에 결과가 있는지는 여기서 알 수
-- 없으므로 백필하지 않는다 — 행이 없으면 앱은 '분석한 적 없음'으로 보고, 편집
-- 화면이 예전처럼 워커에 물어 이미 분석된 것을 확인한 뒤 이 행을 세운다.
-- 잘못된 DONE을 넣는 것보다 모른다고 두는 쪽이 안전하다.
