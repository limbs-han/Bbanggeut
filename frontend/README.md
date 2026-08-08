# 빵긋 Flutter App

백엔드 OpenAPI를 기준으로 구현한 Android 우선 Flutter 앱입니다. Figma 와이어프레임의 화면 흐름과 따뜻한 색감은 참고하되, 실제 API 상태·오류·권한 모델을 우선합니다.

## 실행

```powershell
flutter pub get
flutter run --dart-define=API_BASE_URL=https://i15e201.p.ssafy.io
```

`API_BASE_URL`을 생략하면 위 운영 HTTPS 주소를 기본값으로 사용합니다. 로컬 Android 에뮬레이터에서 백엔드를 실행할 때는 `http://10.0.2.2:8080`처럼 호스트 주소를 지정하세요.

## 릴리즈 APK 만들고 폰에 넣기

**APK는 저장소에 넣지 않습니다.** 120MB짜리 바이너리가 git 이력에 영구히 남고
클론할 때마다 따라옵니다. 필요할 때 아래로 직접 만드세요 — 90초쯤 걸립니다.

```bash
cd frontend && flutter build apk --release
```

결과: `frontend/build/app/outputs/flutter-apk/app-release.apk`

```bash
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

`-r`은 덮어쓰기라 **로그인 상태와 편집 초안이 유지됩니다.**

### 서명과 버전

릴리즈도 디버그 키로 서명합니다(`app/build.gradle.kts`) — 키스토어 없이 바로
빌드됩니다. 대신 **다른 PC에서 만든 APK는 서명이 달라 덮어쓸 수 없습니다.**
그때는 지우고 새로 깔아야 하며 앱 데이터가 사라집니다.

버전은 pubspec이 아니라 **git에서 만듭니다.**

| 항목 | 값 | 예 |
|---|---|---|
| `versionCode` | 커밋 개수(`git rev-list --count HEAD`) | `1047` |
| `versionName` | `1.0.0+<커밋수>.<짧은 해시>` | `1.0.0+1047.a602041` |

작업 트리가 더러우면 `.dirty`가 붙습니다. 설치 후 확인:

```bash
adb shell dumpsys package com.williamjames.william_james_app | grep versionName
```

**다운그레이드는 막힙니다.** `master`는 병합 커밋이 쌓여 `develop`이나 기능
브랜치보다 `versionCode`가 큽니다. master 빌드가 깔린 폰에 기능 브랜치 빌드를
넣으려면 `INSTALL_FAILED_VERSION_DOWNGRADE`가 나므로, 그 브랜치를 최신 master에
올리거나 앱을 지우고 설치해야 합니다(데이터 사라짐).

### 실행 인자 (`--dart-define`)

| 이름 | 형태 | 생략하면 |
|---|---|---|
| `API_BASE_URL` | `--dart-define=API_BASE_URL=https://i15e201.p.ssafy.io` | 위 운영 HTTPS 주소 |
| `COMIC_SERVER` | `--dart-define=COMIC_SERVER=false` | 4컷 만화가 **실서버**를 호출(기본값) |

4컷 만화(FN-A40)는 기본으로 우리 서버의 `POST /api/videos/{videoId}/comic/script`·`/comic/image`를 호출합니다. `COMIC_SERVER=false`를 주면 `FakeComicGateway`가 붙어 고정된 견본 대사와 색 블록 그림을 돌려주고, 만화 화면 위쪽에 견본이라는 알림이 뜹니다 — 서버 없이 기기에서 흐름만 걸어 볼 때 씁니다.

**기본을 실서버로 둔 이유**: 인자를 붙이는 걸 잊으면 오류가 아니라 **가짜 만화가 그대로 출고됩니다.** 잊었을 때 실패하는 쪽이 조용히 가짜를 내보내는 쪽보다 낫습니다.

**`bool.fromEnvironment`는 문자열 `true`와 `false`만 알아봅니다.** `1`, `no`, `FALSE`는 오류 없이 조용히 무시되어 기본값(실서버)이 됩니다 — 견본을 켤 때 값을 정확히 `false`로 적으세요.

## 구현된 연동

- 회원가입, 로그인, refresh token rotation, 로그아웃, 회원 탈퇴, 비밀번호 변경·재설정, 프로필 수정
- 기기 목록, 8자리 일회용 등록 코드(QR 포함) claim, 상태·통계, 이름·보관 기간
- 영상 목록, 트리거·이벤트 타입 필터, 재생·다운로드 단기 URL, 즐겨찾기, 삭제
- 로컬 영상 편집기(프레임 타임라인·비율 5종·필터 5종·자막·이모지 스티커·구간 줌·Media3 내보내기), AR 얼굴 추적 스티커, ML Kit 자동 자막 — `VIDEO_EDITOR.md` 참고
- 서버 자동 편집 추천(editor-api) 연동 — 업로드→분석 폴링→추천 컷·줌, 완성본 업로드·가족 댓글
- 이메일 귀속 초대(받은 초대함 수락·거절), 멤버 요청 링크 딥링크, 구성원 권한 회수, 소유권 이전, 추억 금고(Vault)
- 라이브 세션 생성, PENDING polling, 15초 heartbeat, WHEP(WebRTC) 재생, 양방향 오디오(talkback WHIP), 종료
- 캘린더 일정 CRUD(API-74~77), 알림 설정 서버 저장(API-78·79), 웃음 리포트 서버 집계(API-46)
- FCM 푸시 토큰 등록·해제와 인앱 알림함, 구독 상태 조회·활성화·해지, 접근 로그 조회
- 4컷 만화(`COMIC_SERVER=true`일 때 서버 호출, 기본은 견본 응답)

## 아직 실제 기기가 필요한 검증

- 카메라가 생성한 등록 코드 claim
- 실제 업로드 영상의 썸네일·재생·다운로드
- WHEP 라이브 READY 전환과 장시간 heartbeat(Wi-Fi·LTE 각각)
- 실제 기기별 미디어 앱으로 로컬 편집본 저장 확인
