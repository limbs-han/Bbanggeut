// 혼합 부하 — API 읽기 · 원본 업로드 · AI 분석을 겹쳐서 서로 간섭을 잰다.
//
// 왜 혼합인가: 네 축(API·라이브·저장소·분석)이 같은 4 vCPU와 같은 EBS 볼륨을
// 나눠 쓴다. 축별 단독 측정은 나머지 축이 유휴일 때의 숫자라서 운영 상태를
// 대표하지 못한다 — k6-read-path.js가 350 VU에서 p95 9 ms로 "한계 미도달"이
// 나온 이유가 그것이다(그때 업로드도 분석도 돌지 않았다).
//
// 이 스크립트는 API 읽기 부하를 처음부터 끝까지 일정하게 유지하고(측정자),
// 분석과 업로드를 시간차로 켠다. 모든 API 요청에 현재 구간을 태그로 붙이므로
// k6 요약 자체가 구간별 p95 비교표가 된다:
//
//   baseline       API만
//   with_analysis  API + 분석
//   with_upload    API + 분석 + 업로드
//   recovery       부하를 끈 뒤 회복 확인
//
// 사전 준비: ./prepare.sh 가 .work/ 에 분석 대상과 업로드 URL을 만든다.
// 실행:
//   docker run --rm --network host \
//     -e BASE_URL=https://i15e201.p.ssafy.io -e ACCESS_TOKEN="$TOKEN" \
//     -v "$PWD/ci/load:/scripts" grafana/k6 run /scripts/mixed-load.js
//
// 부하 발생기는 운영 인스턴스 밖에서 돌린다. 같은 EC2에서 돌리면 k6가 CPU를
// 나눠 써서 측정 대상이 오염된다.
import http from 'k6/http';
import exec from 'k6/execution';
import { check, sleep } from 'k6';
import { SharedArray } from 'k6/data';
import { Trend, Counter } from 'k6/metrics';

const BASE_URL = __ENV.BASE_URL || 'https://i15e201.p.ssafy.io';
const TOKEN = __ENV.ACCESS_TOKEN || '';

// 구간 경계(초). prepare.sh가 만든 대상 수에 맞춰 조정한다.
const PHASE_BASELINE_END = Number(__ENV.PHASE_BASELINE_END || 120);
const PHASE_ANALYSIS_END = Number(__ENV.PHASE_ANALYSIS_END || 300);
const PHASE_UPLOAD_END = Number(__ENV.PHASE_UPLOAD_END || 480);
const TOTAL_DURATION = Number(__ENV.TOTAL_DURATION || 600);

const API_VUS = Number(__ENV.API_VUS || 30);
const ANALYSIS_VUS = Number(__ENV.ANALYSIS_VUS || 4);
const UPLOAD_VUS = Number(__ENV.UPLOAD_VUS || 8);

// 분석 대상과 업로드 URL은 init 단계에서 한 번만 읽는다. SharedArray는 VU
// 사이에서 메모리를 공유하므로 VU를 늘려도 메모리가 선형으로 늘지 않는다.
const config = JSON.parse(open('./.work/config.json'));
const analysisTargets = new SharedArray('analysis', () =>
  JSON.parse(open('./.work/analysis-targets.json')));
const uploadUrls = new SharedArray('uploads', () => {
  try {
    return JSON.parse(open('./.work/upload-urls.json'));
  } catch (e) {
    // 기기 credential 없이 돌리는 경우 — 업로드 시나리오만 건너뛴다.
    return [];
  }
});

// 업로드 본문. 실제 이벤트 클립이 10~16 MB이므로 그 크기를 기본으로 둔다.
// 500 MiB 최악 케이스는 k6 메모리에 담기 어려우니 storage-io.sh로 따로 잰다.
const payload = uploadUrls.length > 0 ? open('./.work/payload.bin', 'b') : null;

// 분석 큐 대기를 직접 재는 지표. 202를 받은 시점부터 stage가 download/audio를
// 벗어날 때까지가 대기다 — 워커가 1개라 앞 작업이 끝나기를 기다린 시간이다.
const analysisAccepted = new Counter('wj_analysis_accepted');
const analysisCached = new Counter('wj_analysis_cached');
const analysisRejected = new Counter('wj_analysis_rejected');
const uploadThroughput = new Trend('wj_upload_mbps');

export const options = {
  scenarios: {
    // 측정자. 전 구간 일정하게 유지해야 구간 비교가 성립한다.
    api_read: {
      executor: 'constant-vus',
      vus: API_VUS,
      duration: `${TOTAL_DURATION}s`,
      exec: 'apiRead',
    },
    // 분석은 baseline이 끝난 뒤 켠다.
    analysis: {
      executor: 'constant-vus',
      vus: ANALYSIS_VUS,
      startTime: `${PHASE_BASELINE_END}s`,
      duration: `${PHASE_UPLOAD_END - PHASE_BASELINE_END}s`,
      exec: 'triggerAnalysis',
    },
    // 업로드는 분석이 이미 돌고 있는 상태에서 켠다 — 최악 조합이 목표다.
    upload: {
      executor: 'constant-vus',
      vus: UPLOAD_VUS,
      startTime: `${PHASE_ANALYSIS_END}s`,
      duration: `${PHASE_UPLOAD_END - PHASE_ANALYSIS_END}s`,
      exec: 'uploadOriginal',
    },
  },
  thresholds: {
    // baseline은 기존 측정(p95 9 ms)과 같은 조건이므로 넉넉히 잡아도 통과한다.
    // 나머지 구간은 임계값을 통과/실패로 쓰지 않고 비교값으로 읽는다 —
    // 그래서 abortOnFail을 쓰지 않는다. 목표는 실패시키는 게 아니라 배수를
    // 남기는 것이다.
    'http_req_duration{kind:api,phase:baseline}': ['p(95)<300'],
    'http_req_duration{kind:api,phase:with_analysis}': ['p(95)<3000'],
    'http_req_duration{kind:api,phase:with_upload}': ['p(95)<3000'],
    'http_req_duration{kind:api,phase:recovery}': ['p(95)<300'],
    // API가 부하 중에 죽지는 않아야 한다. 느려지는 것과 실패하는 것은 다르다.
    'http_req_failed{kind:api}': ['rate<0.01'],
  },
  // 요약에 p95 외에 p99도 남긴다 — 꼬리 지연이 경합의 신호다.
  summaryTrendStats: ['avg', 'min', 'med', 'p(95)', 'p(99)', 'max'],
};

function currentPhase() {
  const t = exec.instance.currentTestRunDuration / 1000;
  if (t < PHASE_BASELINE_END) return 'baseline';
  if (t < PHASE_ANALYSIS_END) return 'with_analysis';
  if (t < PHASE_UPLOAD_END) return 'with_upload';
  return 'recovery';
}

function authHeaders() {
  return { Authorization: `Bearer ${TOKEN}`, Accept: 'application/json' };
}

// ── A축: API 읽기 ───────────────────────────────────────────────────────────
// 앱이 홈 화면을 열 때 부르는 묶음. 인증 호출은 요청마다 세션·token_version을
// DB에서 대조하므로(AccessTokenValidator) 인증 경로 비용이 그대로 들어간다.
export function apiRead() {
  const phase = currentPhase();
  const params = { headers: authHeaders(), tags: { kind: 'api', phase } };

  const batch = http.batch([
    ['GET', `${BASE_URL}/health`,
      null, { tags: { kind: 'health', phase, name: 'health' } }],
    ['GET', `${BASE_URL}/api/notifications?limit=30`,
      null, { ...params, tags: { ...params.tags, name: 'notifications' } }],
    ['GET', `${BASE_URL}/api/notifications/unread-count`,
      null, { ...params, tags: { ...params.tags, name: 'unread-count' } }],
    ['GET', `${BASE_URL}/api/schedules`,
      null, { ...params, tags: { ...params.tags, name: 'schedules' } }],
    ['GET', `${BASE_URL}/api/vaults`,
      null, { ...params, tags: { ...params.tags, name: 'vaults' } }],
    // 영상 목록은 저장소 축과 같은 데이터를 만지므로 경합을 가장 먼저 본다.
    // vaultId(또는 deviceId) 중 하나가 필수다 — 없으면 422다.
    ['GET', `${BASE_URL}/api/videos?vaultId=${config.vaultId}&size=30`,
      null, { ...params, tags: { ...params.tags, name: 'videos' } }],
  ]);

  for (const response of batch) {
    check(response, { 'api 2xx': (r) => r.status >= 200 && r.status < 300 });
  }

  // 앱은 한 묶음을 부르고 사용자가 잠깐 본다 — 그 리듬을 흉내 낸다.
  sleep(1);
}

// ── D축: AI 분석 트리거 ─────────────────────────────────────────────────────
// editor-api는 워커가 1개다(analysis_jobs.py: ThreadPoolExecutor(max_workers=1)).
// 동시에 넣어도 순서대로 돌고 큐 상한이 없다 — 그 대기가 얼마나 쌓이는지가
// 여기서 재려는 것이다.
//
// 주의: 이미 분석된 영상은 즉시 done을 돌려준다(_load_cached_analyses).
// 그 응답은 큐를 측정하지 못하므로 wj_analysis_cached로 따로 센다 —
// 이 값이 크면 측정이 성립하지 않았다는 뜻이고, cleanup.sh로 캐시를 지우고
// 다시 돌려야 한다.
export function triggerAnalysis() {
  if (analysisTargets.length === 0) {
    exec.test.abort('분석 대상이 없다 — prepare.sh를 먼저 돌릴 것');
  }
  const phase = currentPhase();
  const target = analysisTargets[exec.scenario.iterationInTest % analysisTargets.length];

  const response = http.put(
    `${BASE_URL}/editor/v1/edit-analyses/${target.videoId}`,
    JSON.stringify({ sourceUrl: target.sourceUrl }),
    {
      headers: { ...authHeaders(), 'Content-Type': 'application/json' },
      tags: { kind: 'analysis', phase, name: 'request-analysis' },
      timeout: '60s',
    });

  if (response.status === 202) {
    analysisAccepted.add(1);
  } else if (response.status === 200) {
    analysisCached.add(1);
  } else {
    analysisRejected.add(1);
  }
  check(response, {
    'analysis accepted or cached': (r) => r.status === 202 || r.status === 200,
  });

  // 상태 폴링. 앱이 하는 대로 진행률을 따라간다. 완료까지 기다리지 않는
  // 이유는 워커가 1개라 큐가 길면 한 iteration이 수 분을 잡기 때문이다 —
  // 완료 시간 측정은 analysis-queue.sh가 전담한다.
  const status = http.get(
    `${BASE_URL}/editor/v1/edit-analyses/${target.videoId}`,
    { headers: authHeaders(), tags: { kind: 'analysis', phase, name: 'analysis-status' } });
  check(status, { 'status 200': (r) => r.status === 200 });

  sleep(5);
}

// ── C축: 원본 업로드 ────────────────────────────────────────────────────────
// presigned PUT이라 Spring은 데이터 경로에 없다 — nginx가 MinIO로 그대로
// 흘린다(proxy_request_buffering off). 그래서 여기서 재는 것은 애플리케이션
// 지연이 아니라 EBS 디스크 경합이다: MinIO와 PostgreSQL이 같은 볼륨을 쓴다.
//
// /complete(API-26)는 부러 부르지 않는다. 목적이 바이트를 디스크에 쓰는 것이고,
// 완료 처리는 무결성 검증(크기·sha256·ETag) 때문에 실패하기 쉽다. 미완료
// 예약은 UploadStateSweepWorker가 30분 뒤 FAILED로 닫는다 — 단, MinIO 객체는
// 남으므로 cleanup.sh로 지워야 한다.
export function uploadOriginal() {
  if (uploadUrls.length === 0) {
    // 기기 credential이 없으면 이 시나리오는 조용히 비운다. storage-io.sh가
    // 같은 디스크 경합을 DB 없이 재는 대안이다.
    sleep(10);
    return;
  }
  const phase = currentPhase();
  const slot = uploadUrls[exec.scenario.iterationInTest % uploadUrls.length];

  const response = http.put(slot.uploadUrl, payload, {
    headers: slot.requiredHeaders || {},
    tags: { kind: 'upload', phase, name: 'presigned-put' },
    timeout: '300s',
  });

  check(response, { 'upload 2xx': (r) => r.status >= 200 && r.status < 300 });
  if (response.status >= 200 && response.status < 300 && response.timings.duration > 0) {
    const megabits = (payload.byteLength * 8) / 1_000_000;
    uploadThroughput.add(megabits / (response.timings.duration / 1000));
  }
}

export function handleSummary(data) {
  // 구간별 p95를 배수로 환산해 바로 읽히게 남긴다. 4단계 재설계의 근거이고,
  // 5단계 재측정에서 같은 표를 그대로 다시 뽑아 비교한다.
  const p95 = (phase) => {
    const metric = data.metrics[`http_req_duration{kind:api,phase:${phase}}`];
    return metric ? metric.values['p(95)'] : null;
  };
  const baseline = p95('baseline');
  const lines = ['', '=== API p95 구간 비교 (measuring stick) ==='];
  for (const phase of ['baseline', 'with_analysis', 'with_upload', 'recovery']) {
    const value = p95(phase);
    if (value === null) {
      lines.push(`${phase.padEnd(14)} 측정값 없음`);
      continue;
    }
    const ratio = baseline ? ` (${(value / baseline).toFixed(1)}배)` : '';
    lines.push(`${phase.padEnd(14)} ${value.toFixed(1)} ms${ratio}`);
  }
  const cached = data.metrics.wj_analysis_cached;
  if (cached && cached.values.count > 0) {
    lines.push('');
    lines.push(`경고: 캐시된 분석 응답 ${cached.values.count}건 — 큐 측정이`);
    lines.push('      그만큼 성립하지 않았다. cleanup.sh --analyses 로 캐시를');
    lines.push('      지우고 다시 돌릴 것.');
  }
  lines.push('');

  // 파일 저장은 SUMMARY_OUT을 줄 때만 한다. k6 컨테이너는 마운트 디렉터리에
  // 쓰기 권한이 없을 수 있고, 10분짜리 측정이 마지막에 쓰기 실패로 끝나면
  // 결과를 통째로 잃는다. 기본은 stdout만이다.
  //   -e SUMMARY_OUT=/scripts/.work/mixed-load-summary.json
  const output = { stdout: lines.join('\n') };
  if (__ENV.SUMMARY_OUT) {
    output[__ENV.SUMMARY_OUT] = JSON.stringify(data, null, 2);
  }
  return output;
}
