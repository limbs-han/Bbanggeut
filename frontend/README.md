# William James Flutter App

백엔드 OpenAPI를 기준으로 구현한 Android 우선 Flutter 앱입니다. Figma 와이어프레임의 화면 흐름과 따뜻한 색감은 참고하되, 실제 API 상태·오류·권한 모델을 우선합니다.

## 실행

```powershell
flutter pub get
flutter run --dart-define=API_BASE_URL=https://i15e201.p.ssafy.io
```

`API_BASE_URL`을 생략하면 위 운영 HTTPS 주소를 기본값으로 사용합니다. 로컬 Android 에뮬레이터에서 백엔드를 실행할 때는 `http://10.0.2.2:8080`처럼 호스트 주소를 지정하세요.

## 구현된 연동

- 회원가입, 로그인, refresh token rotation, 로그아웃, 회원 탈퇴
- 기기 목록, 8자리 일회용 등록 코드 claim, 상태·통계, 이름·보관 기간
- 영상 목록, 트리거 필터, 재생·다운로드 단기 URL, 기기 내 구간 편집·공유, 즐겨찾기, 삭제
- 초대 링크 생성·공유, 가입 요청 조회·승인·거절, 구성원 권한 회수
- 라이브 세션 생성, PENDING polling, 15초 heartbeat, HLS 재생, 종료
- 구독 상태 조회·활성화·해지, 접근 로그 조회

## 아직 실제 기기가 필요한 검증

- 카메라가 생성한 등록 코드 claim
- 실제 업로드 영상의 썸네일·재생·다운로드
- MediaMTX HLS 라이브 READY 전환과 장시간 heartbeat
- 실제 기기별 미디어 앱으로 로컬 편집본 저장·공유 확인
