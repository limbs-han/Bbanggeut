# editor-api 실서버 배포

nginx `/editor/` 라우트와 compose의 `editor-api` 서비스 정의는 기존 백엔드
배포 파이프라인(backend-deploy.tar.gz → wj-deploy-backend)으로 반영된다.
배포 wrapper는 editor-api를 올리거나 내리지 않으므로, **이미지 빌드와
기동만 서버에서 직접** 한다.

## 최초 프로비저닝 (한 번)

1. 개발 PC에서 소스와 모델을 복사한다. 모델 3개는 Git 미추적이라 소스와
   별도로 준비해야 한다(`README.md`의 모델 준비 절 참고).

   ```bash
   scp -r video_editor ubuntu@i15e201.p.ssafy.io:/home/ubuntu/william-james/editor-api
   scp video_editor/models/* ubuntu@i15e201.p.ssafy.io:/home/ubuntu/william-james/editor-models/
   ```

2. 서버 `/home/ubuntu/william-james/infra/.env`에 추가한다:

   ```
   EDITOR_JWT_SECRET=<secrets/app.env의 JWT_SIGNING_KEY와 같은 값>
   ```

   editor-api가 이 값으로 앱의 백엔드 액세스 토큰(HS256, iss=wj-server)을
   직접 검증한다. 값이 비면 컨테이너가 기동을 거부한다
   (`EDITOR_REQUIRE_AUTH=true`).

3. 이미지를 빌드하고 버킷을 만든 뒤 기동한다:

   ```bash
   docker build -t wj-editor-api:latest \
     -f /home/ubuntu/william-james/editor-api/Dockerfile.local \
     /home/ubuntu/william-james/editor-api
   cd /home/ubuntu/william-james/infra
   docker compose --env-file .env run --rm minio-init   # william-james-edit 버킷 생성
   docker compose --env-file .env up -d editor-api
   ```

4. 확인:

   ```bash
   curl -s https://i15e201.p.ssafy.io/editor/health
   ```

   `"analysis": true`(모델 인식), `"authRequired": true`,
   `"vaultScope": true`(가족 범위 검사), `"presignedPlayback": true`가
   나와야 한다. `/v1/*`는 토큰 없이 부르면 401, 남의 가족 영상이면 403이다.

## 갱신

소스 재복사 → `docker build` → `docker compose --env-file .env up -d editor-api`.

## 백엔드 쪽 짝 설정 (FCM 알림·삭제 연동)

- `secrets/app.env`에 `S3_EDIT_BUCKET=william-james-edit` 추가 — 영상 삭제
  워커가 편집 부산물(분석 캐시·초안·편집본·댓글)을 함께 지운다. 비워
  두면 청소만 건너뛴다.
- FCM 푸시는 `FCM_ENABLED=true` + `GOOGLE_APPLICATION_CREDENTIALS`가
  설정된 경우에만 나간다. 꺼져 있어도 알림센터에는 쌓인다.

## 주의

- 백엔드 배포가 실패해 자동 롤백되면 이전 compose(editor-api 정의가 없는
  백업본)의 `--remove-orphans`가 editor-api 컨테이너를 지울 수 있다.
  그때는 `up -d editor-api`로 다시 올리면 된다(데이터는 MinIO 볼륨에 있다).
- 영상 단위 접근은 백엔드 `GET /api/videos/{id}`에 사용자 토큰을 전달해
  판정한다(`EDITOR_BACKEND_URL`, 기본 운영 도메인, 60초 캐시) — 금고
  구성원이 아니면 403이고, 로그아웃한 세션도 백엔드 판정에서 걸러진다
  (캐시 60초 이내는 예외). 백엔드가 죽으면 편집 API도 잠긴다(fail-closed).
- 댓글에는 토큰의 사용자 UUID(`authorUserId`)가 함께 저장된다. 표시
  이름까지 서버가 박으려면 백엔드에 프로필 조회 API가 필요하다.
- 편집본 재생은 MinIO presigned URL(1시간, nginx `/william-james-edit`
  경유)로 나간다 — editor-api가 스트리밍을 물고 있지 않는다.
- 분석은 CPU 작업이다 — 2분 영상에 개발 PC 실측 15~19초였고 EC2에서는 더
  걸릴 수 있다. 작업자 1명이라 동시 요청은 순차 처리된다.
- 분석 원본은 앱이 보낸 백엔드 presigned URL(`sourceUrl`)로 서버가 직접
  받는다. 허용 호스트는 `EDITOR_SOURCE_URL_HOSTS`(기본 i15e201.p.ssafy.io)뿐
  — 그 밖의 주소는 SSRF 방지를 위해 422로 거절한다.
- 앱의 editor-api 기본 주소는 `https://i15e201.p.ssafy.io/editor`다. 로컬
  editor-api로 붙으려면:

  ```bash
  flutter run --dart-define=EDITOR_API_BASE_URL=http://127.0.0.1:18080
  ```

  에 `adb reverse tcp:18080 tcp:18080`을 함께 쓴다.
