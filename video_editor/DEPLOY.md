# editor-api 실서버 배포

editor-api는 백엔드 배포 파이프라인에 **자동으로 포함**된다.
`package-backend-deploy.sh`가 `video_editor/` 소스를 `editor-api/`라는
이름으로 backend-deploy.tar.gz에 담고, 서버의 `wj-deploy-backend`가:

1. 라이브 파일을 바꾸기 전에 릴리스 소스로 이미지를 빌드하고
   (`wj-editor-api:next`, 실패 시 배포 전체가 아무것도 안 바꾼 채 중단),
2. 기존 `wj-editor-api:latest`를 `:previous`로 태그해 롤백 지점을 남기고,
3. `compose up -d editor-api` 후 `127.0.0.1:18080/health` 응답을 기다린다.
4. 배포 실패로 롤백되면 `:previous` 이미지로 editor-api도 되돌린다.

즉 **갱신은 develop → master 병합 뒤 Jenkins 배포 승인만으로 끝난다.**
소스 scp·수동 docker build는 더 이상 필요 없다.

## 최초 프로비저닝 (한 번, 이미 실서버에는 완료됨)

1. 모델 3개는 Git 미추적이라 서버에 따로 둔다(`README.md`의 모델 준비 절):

   ```bash
   scp video_editor/models/* ubuntu@i15e201.p.ssafy.io:/home/ubuntu/william-james/editor-models/
   ```

   모델이 없어도 배포는 진행되고(경고만 출력) editor-api는 뜨지만, 분석
   요청은 503이다.

2. 서버 `/home/ubuntu/william-james/infra/.env`에 추가한다:

   ```
   EDITOR_JWT_SECRET=<secrets/app.env의 JWT_SIGNING_KEY와 같은 값>
   GMS_KEY=<GMS에서 받은 Gemini API 키>
   ```

   `EDITOR_JWT_SECRET`으로 editor-api가 앱의 백엔드 액세스 토큰(HS256,
   iss=wj-server)을 직접 검증한다. 값이 비면 컨테이너가 기동을 거부하므로
   (`EDITOR_REQUIRE_AUTH=true`) 배포 wrapper는 이 값이 없으면 배포를
   시작하지 않는다.

   `GMS_KEY`는 4컷 만화(API-71·72)가 Gemini를 부를 때만 쓴다. **여기 두는
   이유**: 키를 컨테이너 환경변수로만 전달하고 이미지·Git·앱에는 넣지 않는다
   (APK를 뜯으면 앱에 심은 키는 가져갈 수 있다). 비어 있어도 editor-api는
   뜨고 다른 편집 기능은 정상이며 만화 요청만 502가 된다. 키만 바꿀 때는
   재배포 없이 `docker compose --env-file .env up -d editor-api`로 갈아탄다.

3. 확인:

   ```bash
   curl -s https://i15e201.p.ssafy.io/editor/health
   ```

   `"analysis": true`(모델 인식), `"authRequired": true`,
   `"vaultScope": true`(가족 범위 검사), `"presignedPlayback": true`가
   나와야 한다. `/v1/*`는 토큰 없이 부르면 401, 남의 가족 영상이면 403이다.

## 수동 롤백

배포 성공 뒤 editor-api만 이전 버전으로 되돌리려면:

```bash
docker tag wj-editor-api:previous wj-editor-api:latest
cd /home/ubuntu/william-james/infra
docker compose --env-file .env up -d --force-recreate editor-api
```

## 백엔드 쪽 짝 설정 (FCM 알림·삭제 연동)

- `secrets/app.env`에 `S3_EDIT_BUCKET=william-james-edit` 추가 — 영상 삭제
  워커가 편집 부산물(분석 캐시·초안·편집본·댓글)을 함께 지운다. 비워
  두면 청소만 건너뛴다.
- FCM 푸시는 `FCM_ENABLED=true` + `GOOGLE_APPLICATION_CREDENTIALS`가
  설정된 경우에만 나간다. 꺼져 있어도 알림센터에는 쌓인다.

## 주의

- 배포 실패 롤백은 wrapper가 `:previous` 이미지로 editor-api까지 되돌린다.
  단 복원된 compose 백업본이 editor-api 정의가 없는 아주 옛 릴리스라면
  컨테이너가 `--remove-orphans`로 지워질 수 있다 — 그때는
  `up -d editor-api`로 다시 올리면 된다(데이터는 MinIO 볼륨에 있다).
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
