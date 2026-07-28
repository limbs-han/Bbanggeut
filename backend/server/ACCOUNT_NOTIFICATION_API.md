# 계정·알림 API 변경사항

## 권한

기기 권한은 `OWNER`와 `MEMBER`로 구분한다. 기존 `EDITOR`, `VIEWER`
데이터는 Flyway V25에서 `MEMBER`로 전환된다.

- `OWNER`: 기기 설정, 초대·구성원 관리, 소유권 이전, 영상 삭제
- `MEMBER`: 기기·영상 조회, 스트리밍, 영상 메타데이터 수정

초대 생성 요청에서는 `role` 필드를 보내지 않는다. 수락한 사용자는 항상
`MEMBER`가 된다. 초대 이메일은 현재 가입 상태가 `ACTIVE`인 계정이어야 하며,
존재하지 않거나 탈퇴한 이메일은 `INVITEE_ACCOUNT_NOT_FOUND`로 거절된다.

## 비밀번호

- `POST /api/auth/password/change`: 로그인 사용자의 비밀번호 변경
- `POST /api/auth/password/forgot`: 재설정 이메일 요청
- `POST /api/auth/password/reset`: 일회성 토큰으로 비밀번호 재설정

재설정 토큰은 DB에 SHA-256 해시만 저장되고 30분 후 만료된다. SMTP 발송에는
`SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`,
`PASSWORD_RESET_FROM`, `PASSWORD_RESET_URL` 환경 변수를 사용한다.

## 인앱·푸시 알림

다음 시점에 사용자별 알림 레코드를 생성한다.

- 등록된 이메일 계정이 기기 초대를 받았을 때
- `LAUGHTER` 영상 업로드가 `READY` 상태가 되었을 때

웃음 영상 알림은 해당 기기의 모든 활성 `OWNER`, `MEMBER`에게 생성된다.
중복 키가 있어 업로드 완료 요청이 재시도되어도 알림은 한 번만 저장된다.

- `GET /api/notifications`
- `GET /api/notifications/unread-count`
- `PATCH /api/notifications/{notificationId}/read`
- `PATCH /api/notifications/read-all`

### FCM 토큰

- `PUT /api/notifications/push-tokens`: 현재 설치의 FCM 토큰 등록·갱신
- `DELETE /api/notifications/push-tokens/{installationId}`: 로그아웃·알림 해제 시 제거

등록 본문은 다음과 같다.

```json
{
  "installationId": "앱 설치를 식별하는 안정적인 임의 ID",
  "token": "Firebase Messaging에서 발급한 FCM 토큰",
  "platform": "ANDROID"
}
```

`platform`은 `ANDROID` 또는 `IOS`다. 동일 설치의 토큰 갱신과 동일 토큰의
사용자 전환을 처리하며, 사용자 탈퇴 시 토큰도 함께 삭제된다.

새 인앱 알림이 DB에 커밋된 다음 Firebase Admin SDK로 같은 대상에게 푸시한다.
초대 알림은 초대받은 계정, 웃음 영상 알림은 해당 기기의 모든 활성 구성원이
대상이다. FCM이 만료·해제 토큰을 반환하면 서버에서 자동 삭제한다. 푸시 발송
장애는 이미 저장된 인앱 알림을 롤백하지 않는다.

운영 활성화에는 `FCM_ENABLED=true`, `FIREBASE_PROJECT_ID`,
`GOOGLE_APPLICATION_CREDENTIALS`가 필요하다. 서비스 계정 파일은 서버에만
보관하며 앱이나 저장소에 넣지 않는다. Flutter는 알림 권한 요청, 토큰 발급·갱신,
위 API 호출, 수신 메시지와 딥링크 처리를 담당한다.
