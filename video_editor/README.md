# Server video editor

STT 없이 오디오 이벤트, 음향 변화, 영상 정보, 얼굴 표정을 결합해 자동 컷과 줌 recipe를 생성한다.

## 분석 구성

- `yamnet_analysis.py`: speech, laughter, reaction, music 등 오디오 이벤트 분류
- `audio_features.py`: dBFS, 상대 음량, 음량 상승, spectral flux
- `video_features.py`: 움직임, 장면 전환, 영상 품질, 얼굴 위치와 크기
- `expression_analysis.py`: MediaPipe Face Landmarker 표정 반응
- `adaptive_selector.py`: 멀티모달 사건 점수와 연속 구간 선택
- `duration_presets.py`: short, medium, long 길이 프리셋 적용
- `zoom_planner.py`: 표정과 소리가 함께 강한 구간의 얼굴 중심 줌 계획
- `render_video.py`: FFmpeg H.264/AAC 컷·줌 렌더링

Whisper, Qwen, STT 단어 밀도, 문장 경계, 자동 자막은 사용하지 않는다.

## 로컬 검증

```bash
python -m unittest -v video_editor.test_cut_selector
python -m compileall -q video_editor
```

## 모델 준비 (Git 미추적)

분석은 `video_editor/models/`의 모델 세 개를 쓴다. 모델 바이너리는 Git에
넣지 않으므로 없으면 MediaPipe 공식 저장소에서 받아 둔다:

- `yamnet.tflite` — mediapipe-models `audio_classifier/yamnet`
- `blaze_face_full_range.tflite` — 검증 fixture를 만들 때 쓴 얼굴 검출 모델
- `face_landmarker.task` — mediapipe-models `face_landmarker` float16

모델이 없으면 서버는 뜨지만 `/health`의 `analysis`가 false가 되고 새 영상
분석 요청은 503으로 거절한다(fixture 5개는 그대로 동작).

## 앱 연동용 로컬 Docker API

다섯 검증 영상에서 실제로 추출한 YAMNet·음량·영상·표정 분석 JSON을
`fixtures/analysis`에 둔다. 로컬 API도 별도 하드코딩 구간을 반환하지 않고
`build_adaptive_recipe`를 다시 실행해 컷과 줌 레시피를 만든다.

fixture에 없는 영상은 앱이 원본을 올려 분석시킨다:

1. `PUT /v1/edit-analyses/<videoId>` — 원본 MP4를 통째로 업로드. 202와
   함께 작업 상태를 돌려주고 백그라운드에서 음량→YAMNet→영상→표정
   순서로 분석한다(2분 영상 기준 개발 PC 실측 15~19초).
2. `GET /v1/edit-analyses/<videoId>` — `{status, stage, progress}` 폴링.
   `done`이면 결과가 MinIO `edit-analyses/<videoId>/`에 남는다.
3. `POST /v1/edit-recommendations` — fixture가 없으면 이 분석 결과로
   레시피를 만든다. 분석 전이면 404(detail `analysis-required`).

```powershell
$env:MQTT_PASSWORD='local-edit-unused'
docker compose `
  -f backend/docker-compose.yml `
  -f video_editor/docker-compose.local.yml `
  up -d minio minio-init editor-api
adb reverse tcp:18080 tcp:18080
```

앱의 기본 editor-api 주소는 운영(`https://i15e201.p.ssafy.io/editor`)이다.
로컬 editor-api로 붙으려면 앱을 이렇게 띄운다:

```bash
flutter run --dart-define=EDITOR_API_BASE_URL=http://127.0.0.1:18080
```

로컬은 `EDITOR_JWT_SECRET`이 없어서 인증이 꺼진 채 뜬다(루프백 전용).
실서버 배포는 `DEPLOY.md` 참고 — 거기서는 백엔드와 같은 HS256 시크릿으로
앱 액세스 토큰을 검증한다.

상태 확인은 `http://127.0.0.1:18080/health`로 한다. 앱은
`POST /v1/edit-recommendations`에 영상 ID와 로컬 시각의 촬영 시각을 보내고,
API는 추천 레시피를 반환하는 동시에 MinIO의
`edit-projects/<videoId>/auto-v1.json`에 저장한다. 사용자가 고친 레시피는
`PUT /v1/edit-projects/<videoId>`로 별도 객체에 저장한다.

분석 의존성은 `requirements-analysis.txt`에 있다. 모델 바이너리는 Git에 넣지 않는다.

```bash
python -m video_editor.yamnet_analysis \
  --model /models/yamnet.tflite \
  --output-dir /tmp/analysis video.mp4

python -m video_editor.audio_features \
  --output-dir /tmp/analysis video.mp4

python -m video_editor.video_features \
  --face-model /models/blaze_face_full_range.tflite \
  --output-dir /tmp/analysis video.mp4

python -m video_editor.expression_analysis \
  --model /models/face_landmarker.task \
  --output-dir /tmp/analysis video.mp4
```

recipe 생성:

```bash
python -m video_editor.adaptive_cli \
  --yamnet /tmp/analysis/video.yamnet.json \
  --audio /tmp/analysis/video.audio.json \
  --video /tmp/analysis/video.video.json \
  --expression /tmp/analysis/video.expression.json \
  --duration-preset medium \
  --zoom on \
  --output /tmp/recipe-v10.json
```

길이 프리셋은 `short=15~30초`, `medium=35~65초`, `long=70~120초`다.

STT 문맥을 사용하지 않으므로 프리셋은 이야기의 의미적 완결성이 아니라 사건 점수와 음향·장면 경계를 기준으로 선택한다.

줌은 MediaPipe blendshape 표정 점수 65%와 같은 시점의 웃음·반응음·음량 상승·음악 점수 35%를 결합한다. 얼굴 목표 높이는 화면의 28~33.3%, 배율은 1.20~2.80배, 길이는 1.2~4초다. 줌 전환 램프는 사용하지 않는다.

렌더링:

```bash
python -m video_editor.render_video \
  --source video.mp4 \
  --recipe /tmp/recipe-v10.json \
  --output /tmp/video-edited.mp4
```

## 현재 제약

- 음향·영상 신호만으로 대화 주제나 이야기 의미를 이해하지는 못한다.
- 사람이 많은 고정 카메라 환경에서는 YAMNet speech 점수가 영상 대부분에서 높을 수 있다.
- 최종 시작·끝과 줌은 앱에서 사용자가 수정할 수 있어야 한다.
- 분석 작업자는 한 명이라 여러 영상을 동시에 올리면 차례대로 처리한다.
- 분석 실패 시 자동 재시도는 없다 — 앱이 다시 업로드하면 처음부터 돈다.
- 작업 상태는 프로세스 메모리에만 있어서 서버를 재시작하면 진행 중이던
  분석은 사라진다(완료된 결과는 MinIO에 남는다).
