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

## 4컷 만화 워커 (API-71·API-72)

앱은 이 서비스를 **직접 부르지 않는다.** Spring이 인증·권한을 확인하고 원본 presigned
URL을 붙여 아래 라우트로 넘긴다. 그래서 여기에는 JWT 검증이 없고 외부에 노출하지 않는다.

```
POST /v1/comic/{videoId}/script   {videoUrl, lines:[{startMs,text}], frameCount?}  → {cuts:[4개]}
POST /v1/comic/{videoId}/image    {cuts:[4개], style}                              → {image: "<base64 PNG>"}
```

- **1단계**는 원본에서 프레임 4~6장(기본 5)을 뽑아 자막과 함께 `gemini-3.5-flash`에
  넣고, 4컷 구성과 함께 **인물·배경 시트**를 받는다. 시트는 응답에 담지 않고
  `comic/{videoId}/sheet.json`에 남긴다 — 2단계가 프롬프트를 조립할 재료다.
- **2단계**는 시트를 꺼내 `gemini-2.5-flash-image`에 넣는다. 시트가 없으면 시트 없이
  조립한다(품질만 떨어지고 실패시키지 않는다).
- 프레임 수를 함부로 늘리지 마라. 실측(2026-08-03, GMS)으로 **이미지 한 장이 크기와
  무관하게 입력 1,089토큰**이고, 이 모델은 생각 토큰(`thoughtsTokenCount`)도 쓴다.
  영상을 초당 1장으로 통째로 넣으면 13만 토큰이 된다.
- `gemini-3.5-flash`는 **이미지를 만들지 못한다**(실측 확인 — 그림 대신 HTML/CSS 코드를
  글로 써 줬다). 그림 모델을 바꿀 때 이 점을 먼저 확인할 것.
- 응답의 `image`는 **순수 base64**다. `data:image/png;base64,` 접두어를 붙이면 앱의
  `base64Decode`가 터진다.
- 대사(`dialogue`)는 **그림 프롬프트에 넣지 않는다.** 보여주면 모델이 그 글자를 그림에
  쓰고, 앱이 얹는 자막과 겹친다.

환경변수: `GMS_KEY`(필수), `COMIC_SCRIPT_MODEL`, `COMIC_IMAGE_MODEL`,
`COMIC_FRAME_COUNT`(1~8, 기본 5), `COMIC_TIMEOUT_SECONDS`(기본 150 — 앱이 180초까지
기다리므로 서버가 먼저 끊어야 한다), `GMS_BASE_URL`.

`ffmpeg`·`ffprobe`가 필요하다(프레임 추출, 정사각 PNG 보정). `Dockerfile.local`이 설치한다.

테스트(네트워크·ffmpeg 없이 도는 부분만):

```bash
python -m unittest ai.video_editor.test_comic -v
```

## 현재 제약

- 음향·영상 신호만으로 대화 주제나 이야기 의미를 이해하지는 못한다.
- 사람이 많은 고정 카메라 환경에서는 YAMNet speech 점수가 영상 대부분에서 높을 수 있다.
- 최종 시작·끝과 줌은 앱에서 사용자가 수정할 수 있어야 한다.
- MinIO 입출력, 비동기 edit job, 실패 재시도, 진행률 API는 아직 연결하지 않았다.
