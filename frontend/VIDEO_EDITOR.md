# 직접 구현 영상 편집기

이벤트 영상 상세 화면의 기존 라우팅과 결과 경로 반환 계약은 유지하면서,
편집 UI와 프로젝트 상태는 Flutter에서 직접 관리한다. Banuba Video Editor
기본 화면과 `ve_sdk_flutter`는 사용하지 않는다.

## 구성

- `lib/editor/editor_project.dart`: 클립, 캔버스, 레이어, 오디오, 내보내기 DTO
- `lib/editor/editor_project_controller.dart`: 분할, 삭제, 복제, 트림, 실행 취소
- `lib/editor/editor_workspace.dart`: 크림·코랄 반응형 편집 화면
- `lib/editor/editor_platform.dart`: Android/iOS 영상 처리 MethodChannel 계약
- `android/.../EditorProjectExporter.kt`: Media3 Composition 내보내기
- `android/.../EditorLayerOverlay.kt`: 정규화 좌표 텍스트·스티커 오버레이

자동 자막 생성과 캐시 코드는 `lib/features/stt`에 그대로 유지한다. 편집기는
기존 컨트롤러가 제공하는 자막 구간을 클립 순서에 맞게 재배치해 네이티브
내보내기에 전달한다.

## Android 지원 범위

- 원본 메타데이터와 실제 프레임 썸네일
- 다중 클립 트림, 분할 결과 연결, 삭제, 복제
- 원본/9:16/16:9/1:1/4:5 캔버스
- 확대, 이동, 회전
- 원본 오디오 볼륨과 음소거
- 시각별 텍스트·스티커와 기존 자동 자막
- 진행률 조회, 취소, H.264 내보내기, MediaStore 저장

지역 블러는 커스텀 셰이더가 없으므로 요청 시 명시적 오류를 반환한다.

## Face AR 제한

`banuba_sdk 3.1.5`와 기존 `BANUBA_LICENSE_TOKEN` 설정은 Face AR용으로
유지한다. 해당 플러그인의 공개 API는 카메라와 정지 이미지 입력만 제공하고
저장된 로컬 동영상 입력이나 파일 렌더링 API는 제공하지 않는다. 따라서
카메라 AR을 로컬 영상 AR처럼 연결하지 않는다. 로컬 영상 프레임 입력과
오프라인 렌더링이 포함된 Banuba 제품/라이선스가 확인되면 AR 패널과
내보내기 전처리 단계에 연결해야 한다.

## iOS

현재 저장소의 `frontend`에는 `ios/` Flutter Runner가 없다. AVFoundation
구현은 Runner와 Xcode 프로젝트가 복구된 후 동일 DTO 계약으로 추가해야 한다.
