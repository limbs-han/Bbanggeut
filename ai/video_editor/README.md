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
python -m unittest -v ai.video_editor.test_cut_selector
python -m compileall -q ai/video_editor
```

## 앱 연동용 로컬 Docker API

다섯 검증 영상에서 실제로 추출한 YAMNet·음량·영상·표정 분석 JSON을
`fixtures/analysis`에 둔다. 로컬 API도 별도 하드코딩 구간을 반환하지 않고
`build_adaptive_recipe`를 다시 실행해 컷과 줌 레시피를 만든다.

```powershell
$env:MQTT_PASSWORD='local-edit-unused'
docker compose `
  -f backend/docker-compose.yml `
  -f ai/video_editor/docker-compose.local.yml `
  up -d minio minio-init editor-api
adb reverse tcp:18080 tcp:18080
```

상태 확인은 `http://127.0.0.1:18080/health`로 한다. 앱은
`POST /v1/edit-recommendations`에 영상 ID와 로컬 시각의 촬영 시각을 보내고,
API는 추천 레시피를 반환하는 동시에 MinIO의
`edit-projects/<videoId>/auto-v1.json`에 저장한다. 사용자가 고친 레시피는
`PUT /v1/edit-projects/<videoId>`로 별도 객체에 저장한다.

분석 의존성은 `requirements-analysis.txt`에 있다. 모델 바이너리는 Git에 넣지 않는다.

```bash
python -m ai.video_editor.yamnet_analysis \
  --model /models/yamnet.tflite \
  --output-dir /tmp/analysis video.mp4

python -m ai.video_editor.audio_features \
  --output-dir /tmp/analysis video.mp4

python -m ai.video_editor.video_features \
  --face-model /models/blaze_face_full_range.tflite \
  --output-dir /tmp/analysis video.mp4

python -m ai.video_editor.expression_analysis \
  --model /models/face_landmarker.task \
  --output-dir /tmp/analysis video.mp4
```

recipe 생성:

```bash
python -m ai.video_editor.adaptive_cli \
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
python -m ai.video_editor.render_video \
  --source video.mp4 \
  --recipe /tmp/recipe-v10.json \
  --output /tmp/video-edited.mp4
```

## 현재 제약

- 음향·영상 신호만으로 대화 주제나 이야기 의미를 이해하지는 못한다.
- 사람이 많은 고정 카메라 환경에서는 YAMNet speech 점수가 영상 대부분에서 높을 수 있다.
- 최종 시작·끝과 줌은 앱에서 사용자가 수정할 수 있어야 한다.
- MinIO 입출력, 비동기 edit job, 실패 재시도, 진행률 API는 아직 연결하지 않았다.
