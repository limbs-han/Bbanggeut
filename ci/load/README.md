# 부하 테스트

## 왜 다시 만들었는가

첫 측정(`k6-read-path.js`, 2026-08-04)은 **읽기 경로만** 쟀다. 350 VU에서 p95가
9 ms이고 실패가 0이라 "한계를 찾지 못했다"는 결론이 나왔는데, 그때 업로드도
분석도 라이브도 돌지 않았다. 나머지 축이 전부 유휴인 상태의 숫자다.

이 서비스에서 경합하는 자원으로 묶으면 축이 네 개다. 그리고 **네 축이 같은
4 vCPU와 같은 EBS 볼륨을 나눠 쓴다.**

| 축 | 기능 | 경로 | 병목 자원 |
| --- | --- | --- | --- |
| A. API | 로그인·기기·금고·영상목록·캘린더·통계·알림 | nginx → Spring(8081) → PG/Redis | CPU, DB 커넥션 |
| B. 라이브 | 실시간 시청(WHEP), 발화(WHIP) | nginx → MediaMTX(8889) + UDP 8189 | 네트워크, SRTP CPU |
| C. 저장소 | 업로드·재생·다운로드 | nginx → **MinIO 직행**(presigned) | 디스크 I/O |
| D. AI 분석 | 자동 편집 4단계 분석 | nginx → editor-api(18080) | CPU(**워커 1개**) |

그래서 축별 단독 측정만으로는 아무것도 증명되지 않는다. 이 디렉터리의 핵심은
`mixed-load.js` — **API 지연을 측정자(measuring stick)로 고정하고 다른 축을
시간차로 켜서 같은 실행 안에서 구간별 p95를 비교**한다.

## 스크립트

| 파일 | 축 | 어디서 돌리나 | 부작용 |
| --- | --- | --- | --- |
| `prepare.sh` | — | 부하 발생기 | 없음(대상 목록·서명 URL만 모은다) |
| `k6-read-path.js` | A | 부하 발생기 | 없음 |
| `mixed-load.js` | **A+C+D** | 부하 발생기 | MinIO 객체·예약 row 생성 |
| `analysis-queue.sh` | D | 부하 발생기 | 분석 캐시 생성 |
| `whep-viewers.py` | B | 부하 발생기 | 스트림 세션 생성(기기 송출을 깨운다) |
| `storage-io.sh` | C | **운영 서버** | 테스트 버킷에 쓰기(스스로 정리) |
| `cleanup.sh` | — | **운영 서버** | 위 잔여물 삭제 |

부하 발생기는 **운영 인스턴스 밖**에서 돌린다. 첫 측정은 k6를 같은 EC2에서
돌려 CPU를 나눠 썼고, 그래서 그 숫자는 보수적인 값이었다.

## 실행 순서

```bash
# 0. 준비 — 액세스 토큰은 15분 만료다. 여기서부터 부하까지를 벌리지 말 것.
ACCESS_TOKEN=<앱 액세스 토큰> ./ci/load/prepare.sh
# 업로드 시나리오까지 돌리려면 기기 credential이 필요하다(ROLE_DEVICE_OPERATING)
ACCESS_TOKEN=... DEVICE_TOKEN=... DEVICE_ID=<uuid> ./ci/load/prepare.sh
```

```bash
# 1-A. 읽기 경로 단독 — 기준선
docker run --rm --network host -e BASE_URL=https://i15e201.p.ssafy.io -e ACCESS_TOKEN="$TOKEN" -v "$PWD/ci/load:/scripts" grafana/k6 run /scripts/k6-read-path.js
```

```bash
# 1-D. 분석 큐 단독
ACCESS_TOKEN="$TOKEN" ./ci/load/analysis-queue.sh
```

```bash
# 1-B. 라이브 동시 시청 단독 (10 → 20 → 40 → 80으로 계단식)
python ci/load/whep-viewers.py --device <deviceId> --viewers 10 --duration 60 --token "$TOKEN"
```

```bash
# 1-C. 저장소 디스크 경합 단독 (서버에서)
ssh ubuntu@i15e201.p.ssafy.io 'cd ~/william-james && ./storage-io.sh'
```

```bash
# 2. 혼합 — 여기가 진짜 측정
docker run --rm --network host -e BASE_URL=https://i15e201.p.ssafy.io -e ACCESS_TOKEN="$TOKEN" -v "$PWD/ci/load:/scripts" grafana/k6 run /scripts/mixed-load.js
```

```bash
# 3. 정리 — 반드시
ssh ubuntu@i15e201.p.ssafy.io 'cd ~/william-james && ./cleanup.sh'
```

부하 중에는 Grafana(`ssh -L 3000:127.0.0.1:3000`)에서 `http_server_requests_seconds`
p95와 `hikaricp_connections_active`를 같이 본다. B축은 MediaMTX API도 함께
본다(`ssh -L 9997:127.0.0.1:9997` 뒤 `--mediamtx-api http://127.0.0.1:9997`).

`whep-viewers.py`는 `pip install aiortc aiohttp`가 필요하다. **부하 발생기 CPU가
포화된 회차는 무효다** — 판정은 MediaMTX의 `readers`·`bytesSent`와 서버 CPU로 한다.

## 안전 규칙

운영 인스턴스가 하나뿐이다. 그래서:

- `storage-io.sh`는 여유 공간을 먼저 확인하고, 모자라면 **아무것도 하지 않고 멈춘다**.
- `cleanup.sh`는 제목이 `loadtest-`로 시작하고 **상태가 READY가 아닌** row만
  지운다(이중 조건). 실제 영상은 건드리지 않는다.
- `mixed-load.js`는 업로드 `/complete`(API-26)를 부르지 않는다. 미완료 예약은
  `UploadStateSweepWorker`가 30분 뒤 FAILED로 닫지만 **MinIO 객체는 남는다** —
  그래서 `cleanup.sh`가 필요하다.
- `.work/`는 `.gitignore`에 있다. presigned URL과 업로드 본문이 들어간다.

## 알려진 측정 함정

- **분석 캐시** — editor-api는 이미 분석된 영상에 즉시 `done`을 돌려준다
  (`_load_cached_analyses`). 그 응답은 큐를 측정하지 못한다. `mixed-load.js`는
  이를 `wj_analysis_cached`로 세어 요약에 경고를 띄우고, `analysis-queue.sh`는
  시작 전에 미리 알려 준다. 재측정 전 `cleanup.sh --analyses`로 지울 것.
- **큐 대기와 처리 중을 구별할 수 없다** — `submit()`이 즉시 job을 만들고
  `status="running"`으로 두므로 대기 중인 건과 처리 중인 건이 상태 응답에서
  같아 보인다. `progress`가 0을 벗어나는 시점을 대기 종료 근사값으로 쓴다.
  이 관측 불가 자체가 개선 대상이다(아래 ①).
- **라이브 토큰 TTL 30초** — `whepUrl`을 받고 곧바로 연결하지 않으면 만료된다.
  실패를 서버 한계로 오독하지 않도록 사유별로 세야 한다.
- **기기당 스트림 1개** — 같은 기기의 시청자들은 송출 하나를 공유한다
  (`findReusableStream`). "동시 스트리밍 몇 개"는 *한 기기의 동시 시청자 수*와
  *동시 송출 기기 수*가 서로 다른 질문이다. B축은 앞쪽을 잰다. 세션 생성은
  `lockDevice(deviceId)`로 기기 단위 직렬화되므로 그 지연도 함께 남긴다.

## 측정 이력

### 2026-08-04 · A축 단독 (운영 EC2, 4 vCPU / 16 GB)

k6를 같은 인스턴스에서 돌렸기 때문에 CPU를 애플리케이션과 나눠 썼다 — 아래
숫자는 **보수적인 값**이다.

| 시나리오 | 최대 VU | 처리량 | p95 | 실패율 |
| --- | ---: | ---: | ---: | ---: |
| 읽기 5종(health·알림·미읽음·일정·금고) | 50 | 112 req/s | 33 ms | 0.00% |
| 인증 읽기 2종(알림·일정) | 350 | **335 req/s** | **9 ms** | 0.00% |

- **한계(knee)를 찾지 못했다.** 50 VU 구간의 p95(33 ms)가 더 컸던 것은 TLS
  핸드셰이크가 섞였기 때문이고, 연결이 재사용되는 정상 상태에서는 한 자릿수 ms다.
- **DB 커넥션 풀은 병목이 아니다.** `hikaricp_connections_active` 최대 4(풀 10).
- 부하 중 load average는 약 4~6이었고 종료 후 즉시 2 이하로 회복했다.
- **결론: 읽기 경로는 MVP 규모에서 병목이 아니다. 한계는 다른 축에 있다.**

### 다음 — 혼합 측정 (미실행)

`mixed-load.js` 요약이 아래 표를 그대로 뽑아 준다. 이것이 재설계 근거이고,
개선 후 같은 스크립트로 다시 뽑아 비교한다.

| 구간 | API p95 | 배수 |
| --- | ---: | ---: |
| baseline (API만) | | 1.0 |
| with_analysis (+분석) | | |
| with_upload (+분석+업로드) | | |
| recovery (부하 종료 후) | | |

## 코드에서 이미 확인된 병목 후보

측정은 아래 네 가지를 숫자로 확정하는 작업이다.

| # | 병목 | 근거 | 재설계 방향 |
| --- | --- | --- | --- |
| ① | 분석 워커 1개, 큐 상한·순번 없음 | `analysis_jobs.py:95` `max_workers=1`, `submit()`이 무조건 수락 | 워커 수 조정 + 큐 상한 + 대기 순번·예상시간 응답 |
| ② | MinIO와 PostgreSQL이 같은 EBS 볼륨 | 둘 다 docker volume, 단일 인스턴스 | MinIO 볼륨 분리 → S3 이전 |
| ③ | 분석 CPU가 API·라이브를 굶김 | 4 vCPU 공유, cgroup 제한 없음 | editor-api CPU 상한 → 별도 인스턴스 |
| ④ | 기기당 시청자 상한 없음 | 백엔드에 시청자 수 제한 없음(TTL만) | 측정된 한계값을 거절 정책으로 |

단건 분석 실측치는 이미 코드에 있다(`analysis_jobs.py:34`, 2분 내외 영상 5개):
음량 0.2s + YAMNet 0.7s + 영상 4.5s + 표정 11s = **약 16.4초**.

## 운영 환경 실측 (2026-08-05)

부하 시나리오의 크기·개수를 여기서 가져온다. 추정이 아니라 운영 실측이다.

**인스턴스** — 4 vCPU / 15 GB RAM / 루트 309 GB(86 GB 사용, 224 GB 여유).

**동시 실행 컨테이너 15개.** 그중 **7개가 Jenkins**다(`jenkins`, 빌드 에이전트
4개, `jenkins-postgres-ci`, `jenkins-redis-ci`). 나머지 8개가 서비스
본체다(postgres·redis·minio·mediamtx·mosquitto·editor-api·prometheus·grafana).
빌드가 도는 동안 4 vCPU를 서비스와 나눠 쓴다 — 분리 순서 1번의 근거다.

**영상 저장 현황** (업로드 완료 269건):

| 항목 | 값 |
| --- | ---: |
| 평균 크기 | 27.2 MB |
| 최대 크기 | 65.8 MB |
| 평균 길이 | 88.5 초 |
| 최대 길이 | 209.3 초 |
| 총 용량 | 7.16 GB |

여기서 따라 나오는 것:

- **평균 비트레이트 약 2.5 Mbps**(27.2 MB ÷ 88.5초). B축 대역폭 계산의 입력값이다.
  시청자 100명이면 약 250 Mbps — 대역폭보다 MediaMTX의 SRTP CPU가 먼저 막힐
  것이라는 가설의 근거다.
- **업로드 본문은 27 MB가 현실값이다.** 저장소 픽스처(12~16 MB)로 재면 디스크
  쓰기량을 절반쯤 적게 잡는다. `prepare.sh`의 기본값을 27 MB로 두었다.
- **분석 시간 실측치(2분 영상 16.4초)는 평균 길이(88.5초)와 거의 맞다.** 즉
  D축 단건 16초는 현실적인 값이고, 최대 길이 209초면 약 2.4배로 늘어난다.

## 이 측정으로 답하지 못하는 것

**무료 저장 용량·영상 길이·가격**은 부하 문제가 아니라 구현 공백이다.
용량 기준 쿼터가 코드에 없다 — 있는 것은 시간 기준뿐이다(금고·기기
`retention_days` 기본 30일, 프리미엄 365일, 영상당 500 MiB 상한).
**사용자별 총량·개수·재생 시간 상한은 없다.**

위 실측으로 절반은 계산된다: 평균 27.2 MB / 88.5초. 남은 입력값은 **기기 1대가
하루에 몇 건을 만드는가**다. 이것까지 나오면 "30일 보관 = 1인당 N GB = 원가 X원"이
확정된다.

```bash
docker exec william-james-postgres-1 psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "select device_id, count(*) clips, min(date(captured_start_at)) first_day, max(date(captured_start_at)) last_day from videos where uploaded_at is not null group by device_id order by clips desc"
```
