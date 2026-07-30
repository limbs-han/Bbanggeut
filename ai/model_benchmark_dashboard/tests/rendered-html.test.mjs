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
  assert.match(html, /YOLO 후보 비교/);
  assert.match(html, /파이프라인 상태/);
  assert.match(html, /LAN 전용/);
  assert.doesNotMatch(html, /Your site is taking shape/);
  assert.doesNotMatch(html, /codex-preview/);
});

test("keeps local-only privacy and benchmark context visible", async () => {
  const response = await render();
  const html = await response.text();

  assert.match(html, /원본 영상·음성은 Jetson 내부에 유지/);
  assert.match(html, /YAMNet baseline/);
  assert.match(html, /YOLO11n/);
  assert.match(html, /30s gap \/ 5m cap/);
});
