import assert from "node:assert/strict";
import test from "node:test";

async function render() {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);

  return worker.fetch(
    new Request("http://localhost/", {
      headers: { accept: "text/html" },
    }),
    {
      ASSETS: {
        fetch: async () => new Response("Not found", { status: 404 }),
      },
    },
    {
      waitUntil() {},
      passThroughOnException() {},
    },
  );
}

test("server-renders the edge observatory dashboard", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);

  const html = await response.text();
  assert.match(html, /<title>WJ Edge Observatory<\/title>/i);
  assert.match(html, /Edge Observatory/);
  assert.match(html, /YOLO 실측 결과 비교/);
  assert.match(html, /발표 질문을 커버하는 모델 선정 근거/);
  assert.match(html, /왜 이 YOLO 모델인가/);
  assert.match(html, /실제 환경에서도 유효한가/);
  assert.match(html, /mAP50-95/);
  assert.match(html, /데이터 소스 상태/);
  assert.match(html, /LAN 전용/);
  assert.doesNotMatch(html, /Your site is taking shape/);
  assert.doesNotMatch(html, /codex-preview/);
});

test("keeps local-only privacy and benchmark context visible", async () => {
  const response = await render();
  const html = await response.text();

  assert.match(html, /원본 영상·음성은 Jetson 내부에 유지/);
  assert.match(html, /수집되지 않은 값은/);
  assert.match(html, /progress\.json/);
  assert.match(html, /실측값이 없는 지표는 N\/A/);
  assert.doesNotMatch(html, /864 \/ 1,200 frames/);
  assert.doesNotMatch(html, /drop 0\.3%/);
  assert.doesNotMatch(html, /데모 스냅샷/);
});
