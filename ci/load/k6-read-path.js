// 읽기 경로 부하 테스트. 단일 EC2에서 nginx → Spring(loopback 8081) →
// PostgreSQL/Redis 경로가 동시 사용자 몇 명까지 목표 지연을 지키는지 본다.
//
// 쓰기(업로드·편집)는 의도적으로 넣지 않았다 — 운영 인스턴스 하나가
// 전부이므로 데이터를 남기지 않는 시나리오만 돌린다.
//
// 실행:
//   docker run --rm --network host \
//     -e BASE_URL=https://i15e201.p.ssafy.io -e ACCESS_TOKEN=<앱 액세스 토큰> \
//     -v "$PWD/ci/load:/scripts" grafana/k6 run /scripts/k6-read-path.js
//
// 토큰은 15분 만료다. 그보다 긴 시나리오를 돌리려면 refresh를 넣어야 한다.
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'https://i15e201.p.ssafy.io';
const TOKEN = __ENV.ACCESS_TOKEN || '';

export const options = {
  // 계단식으로 올려 어느 구간에서 지연이 꺾이는지 본다.
  stages: [
    { duration: '30s', target: 10 },
    { duration: '45s', target: 30 },
    { duration: '45s', target: 50 },
    { duration: '20s', target: 0 },
  ],
  thresholds: {
    // 홈 화면이 여러 호출을 묶어 그리므로 개별 응답은 넉넉히 300ms 안이어야 한다.
    'http_req_duration{kind:api}': ['p(95)<300'],
    http_req_failed: ['rate<0.01'],
  },
};

const authParams = {
  headers: { Authorization: `Bearer ${TOKEN}`, Accept: 'application/json' },
  tags: { kind: 'api' },
};

export default function () {
  // 공개 헬스 — nginx와 Spring이 살아 있는지의 기준선.
  const health = http.get(`${BASE_URL}/health`, { tags: { kind: 'health', name: 'health' } });
  check(health, { 'health 200': (r) => r.status === 200 });

  // 인증 읽기 경로. 요청마다 세션·token_version을 DB에서 대조하므로
  // (AccessTokenValidator) 이 호출들이 곧 인증 경로의 부하다.
  const notifications = http.get(
    `${BASE_URL}/api/notifications?limit=30`,
    { ...authParams, tags: { ...authParams.tags, name: 'notifications' } });
  check(notifications, { 'notifications 200': (r) => r.status === 200 });

  const unread = http.get(
    `${BASE_URL}/api/notifications/unread-count`,
    { ...authParams, tags: { ...authParams.tags, name: 'unread-count' } });
  check(unread, { 'unread 200': (r) => r.status === 200 });

  const schedules = http.get(
    `${BASE_URL}/api/schedules`,
    { ...authParams, tags: { ...authParams.tags, name: 'schedules' } });
  check(schedules, { 'schedules 200': (r) => r.status === 200 });

  const vaults = http.get(
    `${BASE_URL}/api/vaults`,
    { ...authParams, tags: { ...authParams.tags, name: 'vaults' } });
  check(vaults, { 'vaults 200': (r) => r.status === 200 });

  // 앱은 화면을 열 때 한 묶음을 부르고 사용자가 잠깐 본다 — 그 리듬을 흉내 낸다.
  sleep(1);
}
