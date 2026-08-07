# Banuba 영상 편집기

이벤트 영상 상세 화면의 **영상 편집하기** 버튼은 원본 MP4를 임시
디렉터리에 내려받은 뒤 Banuba Video Editor V2를 연다. 편집 결과는
Android에서 H.264 MP4로 내보내고 앱 문서 디렉터리의
`edited_videos` 폴더에 복사한다.

## 실행

라이선스 토큰은 저장소에 커밋하지 않고 `dart-define`으로 전달한다.

```powershell
flutter run `
  --dart-define=API_BASE_URL=https://i15e201.p.ssafy.io `
  --dart-define=BANUBA_LICENSE_TOKEN="<Banuba token>"
```

로컬 개발에서는 Git에서 제외된 `banuba.local.json`을 사용할 수 있다.

```powershell
flutter run --dart-define-from-file=banuba.local.json
```

기본 내보내기는 HD 720p와 H.264다. 기기 자동 해상도 또는 HEVC를
사용하려면 다음 값을 추가한다.

```powershell
--dart-define=BANUBA_EXPORT_QUALITY=auto
--dart-define=BANUBA_USE_HEVC=true
```

GIF 검색을 사용하려면 Giphy 키도 전달한다.

```powershell
--dart-define=GIPHY_API_KEY="<Giphy API key>"
```

## 편집 기능

- Editor V2, 갤러리, Face AR 활성화
- 자르기, 분할, 구간 삭제, 클립 연결 및 순서 변경
- 크롭, 화면 비율, 전환, 미리보기
- LUT, 시각 효과, 이미지·텍스트·GIF 레이어
- 로컬 음악, 원본 음량, 보이스오버 및 음성 효과
- 커버 선택과 종료 시 초안 저장 확인
- 이벤트 영상 편집과 저장된 초안 재진입
- 미리보기 우측의 원형 `AI ✦` 버튼은 현재 이벤트 영상을 검은 여백이
  포함된 720×1280(9:16) H.264 MP4로 먼저 만든 뒤 Banuba AI 편집기를 연다.
- 원본 영상은 잘라내거나 늘리지 않고 화면 중앙에 `scale-to-fit`으로 배치한다.
- Banuba AI Captions가 활성화되며 생성된 자막은 편집기에서 수정할 수 있다.
- AR 효과는 원형 AI 버튼과 분리해 하단 `AR` 편집 메뉴에서 진입

일부 기능은 Banuba 라이선스 플랜과 전달받은 자산에 따라 노출 여부가
달라진다. 빵긋 전용 AR 효과는 아래 Android 경로에 Banuba 효과 폴더를
그대로 추가한다.

```text
android/app/src/main/assets/bnb-resources/effects/<effect-name>/
```

자체 LUT는 Banuba 규격의 PNG를 아래 경로에 추가하고 네이티브 효과
목록에 등록한다.

```text
android/app/src/main/assets/bnb-resources/luts/
```

빵긋 전용 효과음은 실제 음원과 사용 권한 정보가 준비된 뒤 Audio
Browser의 커스텀 콘텐츠 공급자로 연결해야 한다. 현재 구성은 휴대폰의
로컬 음악 라이브러리를 사용한다.

## 주의

Banuba 토큰은 공백 없이 원문 그대로 전달되어야 한다. 토큰이 잘렸거나
ASCII가 아닌 유사 문자가 섞이면 SDK가 `ERR_SDK_NOT_INITIALIZED`를
반환한다.

현재 AI Captions 구성은 Banuba Flutter SDK가 문서에 공개한 시험용
엔드포인트를 사용한다. 운영 배포 전에는 Banuba에서 발급한 운영용
Captions 설정으로 교체해야 한다. AI Clipping은 라이선스 토큰과 별도로
Banuba의 `audioDataUrl`, `audioTracksUrl` 발급이 필요하다.
