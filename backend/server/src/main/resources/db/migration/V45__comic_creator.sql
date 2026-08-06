-- 만화를 만든 사람을 남긴다 — 삭제를 OWNER에게만 열어 둘 이유가 없어서다.
--
-- V44에서는 만든 사람 컬럼이 없었다. 그래서 "지울 수 있는가"를 물으면 금고
-- 역할밖에 볼 것이 없었고, 자기가 만든 만화도 MEMBER는 지우지 못했다.
--
-- **왜 ON DELETE SET NULL인가**: 만든 사람이 탈퇴해도 만화는 가족의 기록으로
-- 남아야 한다. CASCADE로 두면 한 사람이 나가면서 그 사람이 만든 만화와 거기
-- 달린 가족의 좋아요·댓글까지 함께 사라진다.
ALTER TABLE comics
    ADD COLUMN IF NOT EXISTS created_by uuid REFERENCES users(id) ON DELETE SET NULL;

-- 이미 있던 만화는 만든 사람을 알 수 없다(그 정보를 남긴 적이 없다). null로
-- 두고 OWNER만 지울 수 있게 한다 — 모르는 값을 아무에게나 귀속시키면 남의
-- 만화를 지울 수 있는 사람이 생긴다.
COMMENT ON COLUMN comics.created_by IS
    '만화를 만든 사람. V45 이전에 만든 만화는 알 수 없어 null이다.';

-- "내가 만든 만화"를 세는 질의는 아직 없다. 피드는 금고 단위로 읽고 이 컬럼은
-- 행 하나를 이미 집은 뒤에 보는 값이라, 인덱스를 두지 않는다.
