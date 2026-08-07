const fs = require("fs");
const path = require("path");

const sourcePath = path.resolve(__dirname, "../docs/wireframes/source.fragment.html");
const indexPath = path.resolve(__dirname, "../docs/wireframes/index.html");
const html = fs.readFileSync(sourcePath, "utf8");
const indexHtml = fs.readFileSync(indexPath, "utf8");
const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((match) => match[1]);

if (scripts.length !== 1) {
  throw new Error(`Expected one inline script, found ${scripts.length}`);
}
new Function(scripts[0]);

const ids = new Set([...html.matchAll(/\bid="([^"]+)"/g)].map((match) => match[1]));
const queriedIds = [...scripts[0].matchAll(/querySelector\(['"]#([^'"]+)['"]\)/g)].map(
  (match) => match[1],
);
const missingIds = queriedIds.filter((id) => !ids.has(id));
if (missingIds.length) {
  throw new Error(`Missing queried IDs: ${missingIds.join(", ")}`);
}

const screens = new Set(
  [...html.matchAll(/data-screen="([^"]+)"/g)].map((match) => match[1]),
);
if (screens.size !== 8) {
  throw new Error(`Expected eight wireframe screens, found ${screens.size}`);
}

const deviceOptions = new Set(
  [...html.matchAll(/data-device-option="([^"]+)"/g)].map((match) => match[1]),
);
if (deviceOptions.size < 2) {
  throw new Error(`Expected at least two selectable devices, found ${deviceOptions.size}`);
}

const requiredTerms = ["내 기기", "기기 구성원", "공유 사용자", "기기 초대"];
for (const term of requiredTerms) {
  if (!html.includes(term) || !indexHtml.includes(term)) {
    throw new Error(`Missing device-membership term in source or index: ${term}`);
  }
}

const requiredLiveTerms = [
  "시작 대기",
  "15초",
  "45초 TTL",
  "최대 60초",
  "새 세션",
  "120초 hardExpiresAt",
  "H.264/AAC",
  "remux",
  "fan-out",
  "CLOSED/EXPIRED",
];
for (const term of requiredLiveTerms) {
  if (!html.includes(term) || !indexHtml.includes(term)) {
    throw new Error(`Missing on-demand live term in source or index: ${term}`);
  }
}

const legacyTerms = [
  `House${"hold"}`,
  `가${"정 구성원"}`,
  `가${"족 구성원"}`,
  `가${"족 초대"}`,
  `우${"리 집"}`,
];
for (const term of legacyTerms) {
  if (html.includes(term) || indexHtml.includes(term)) {
    throw new Error(`Legacy group term remains in wireframe: ${term}`);
  }
}

if (!html.includes('data-membership-scope="device"')) {
  throw new Error("Member screen is not explicitly scoped to a device");
}
if (!scripts[0].includes("const devices =") || !scripts[0].includes("selectDevice")) {
  throw new Error("Device selection data or behavior is missing from the wireframe script");
}
if (
  !indexHtml.includes("data-membership-scope=&quot;device&quot;") ||
  !indexHtml.includes("data-device-option=&quot;living&quot;")
) {
  throw new Error("Self-contained index.html is not synchronized with the source fragment");
}

const encodedDeviceScript = indexHtml.match(
  /&lt;script&gt;([\s\S]*?const devices =[\s\S]*?)&lt;\/script&gt;/,
);
if (!encodedDeviceScript) {
  throw new Error("Device-selection script is missing from self-contained index.html");
}
const decodeEntities = (value) =>
  value
    .replaceAll("&quot;", '"')
    .replaceAll("&#x27;", "'")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replaceAll("&amp;", "&");
const decodedIndexScript = decodeEntities(encodedDeviceScript[1]);
new Function(decodedIndexScript);

const requiredLiveScriptTerms = [
  "setStreamState",
  "PENDING",
  "READY",
  "CLOSED",
  "EXPIRED",
  "FAILED",
  "wj-stream-start",
  "wj-stream-end",
];
for (const term of requiredLiveScriptTerms) {
  if (!scripts[0].includes(term) || !decodedIndexScript.includes(term)) {
    throw new Error(`Missing live-state behavior in source or index script: ${term}`);
  }
}

for (const legacyStatus of ["STARTING", "ENDED"]) {
  if (scripts[0].includes(legacyStatus) || decodedIndexScript.includes(legacyStatus)) {
    throw new Error(`Legacy StreamSession status remains in source or index: ${legacyStatus}`);
  }
}

console.log(
  `VALID scripts=${scripts.length} queried_ids=${queriedIds.length} ` +
    `screens=${screens.size} devices=${deviceOptions.size} bytes=${Buffer.byteLength(html)}`,
);
