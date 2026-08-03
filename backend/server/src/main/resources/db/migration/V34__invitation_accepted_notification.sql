-- 초대를 보낸 사람에게 "수락됐어요"를 알리는 알림 타입.
-- enum 값 추가는 같은 트랜잭션 안에서 그 값을 쓰면 안 되는 제약이 있어
-- 다른 변경과 섞지 않고 단독 마이그레이션으로 둔다.
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'INVITATION_ACCEPTED';
