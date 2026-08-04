# 부하 테스트

## 무엇을 재는가

`k6-read-path.js`는 앱이 화면을 열 때 부르는 **읽기 경로**를 잰다 —
nginx(TLS) → Spring(loopback 8081) → PostgreSQL/Redis. 인증 호출은 요청마다
세션·`token_version`을 DB에서 대조하므로(`AccessTokenValidator`) 인증 경로의
실제 비용이 그대로 들어간다.

쓰기(업로드·편집·라이브)는 **의도적으로 넣지 않았다.** 운영 인스턴스가 하나뿐이라
데이터를 남기거나 미디어 서버를 흔드는 시나리오는 돌리지 않는다.

## 실행

```bash
# 서버에서 (k6는 컨테이너로 돌린다)
TOKEN=<앱 액세스 토큰>
docker run --rm --network host \
  -e BASE_URL=https://i15e201.p.ssafy.io -e ACCESS_TOKEN="$TOKEN" \
  -v "$PWD/ci/load:/scripts" grafana/k6 run /scripts/k6-read-path.js
```

액세스 토큰은 15분 만료다. 더 긴 시나리오를 돌리려면 스크립트에 refresh를 넣어야 한다.

부하 중에는 Grafana(`ssh -L 3000:127.0.0.1:3000`)에서 `http_server_requests_seconds`
p95와 `hikaricp_connections_active`를 같이 본다.

## 2026-08-04 실측 (운영 EC2, 4 vCPU / 16 GB)

k6를 같은 인스턴스에서 돌렸기 때문에 CPU를 애플리케이션과 나눠 썼다 — 아래 숫자는
**보수적인 값**이다. 별도 부하 발생기를 쓰면 더 나올 여지가 있다.

| 시나리오 | 최대 VU | 처리량 | p95 | 실패율 |
| --- | ---: | ---: | ---: | ---: |
| 읽기 5종(health·알림·미읽음·일정·금고) | 50 | 112 req/s | 33 ms | 0.00% |
| 인증 읽기 2종(알림·일정) | 350 | **335 req/s** | **9 ms** | 0.00% |

- **한계(knee)를 찾지 못했다.** 350 VU에서도 p95가 9 ms이고 실패가 0이다. 50 VU
  구간의 p95(33 ms)가 더 컸던 것은 TLS 핸드셰이크가 섞였기 때문이고, 연결이
  재사용되는 정상 상태에서는 한 자릿수 ms다.
- **DB 커넥션 풀은 병목이 아니다.** `hikaricp_connections_active`가 최대 4(풀 크기
  10)였다 — 쿼리가 짧아 커넥션을 오래 쥐지 않는다. 지금 풀을 늘릴 근거는 없다.
- 부하 중 load average는 약 4~6(4 vCPU)였고, k6가 그중 일부를 차지했다. 부하가
  끝난 뒤 즉시 2 이하로 회복했다.

### 결론

읽기 경로는 MVP 트래픽 규모에서 병목이 아니다. 실제 한계는 다른 곳에 있다.

1. **단일 인스턴스 SPOF** — 처리량이 아니라 가용성이 먼저 문제다.
2. **WHEP 동시 시청·업로드** — 이번에 재지 않은 축. 미디어는 대역폭과 MediaMTX가
   기준이고, 업로드는 MinIO 디스크 I/O가 기준이다.
3. **CPU 경합** — 같은 인스턴스에 Jenkins·MediaMTX·MinIO·editor-api가 함께 있다.
   분석(editor-api)이 도는 동안 API 지연이 어떻게 변하는지가 다음 측정 대상이다.
