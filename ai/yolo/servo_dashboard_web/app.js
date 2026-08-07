const byId = (id) => document.getElementById(id);
const number = (value, fallback = 0) =>
  Number.isFinite(Number(value)) ? Number(value) : fallback;
const fixed = (value, digits = 2) => number(value).toFixed(digits);
const signed = (value, digits = 3) => {
  const numeric = number(value);
  return `${numeric >= 0 ? "+" : ""}${numeric.toFixed(digits)}`;
};
const clamp = (value, min, max) => Math.max(min, Math.min(max, value));
const text = (id, value) => { byId(id).textContent = value; };

let latestEvents = [];
let logPaused = false;
let lastSuccessAt = 0;

function setConnection(online, label) {
  const dot = byId("connection-dot");
  dot.classList.toggle("online", online);
  dot.classList.toggle("offline", !online);
  text("connection-label", label);
}

function updateErrorBar(id, value) {
  const normalized = clamp(number(value), -1, 1);
  const bar = byId(id);
  const width = Math.abs(normalized) * 50;
  bar.style.width = `${width}%`;
  bar.style.left = normalized < 0 ? `${50 - width}%` : "50%";
}

function updateVision(vision) {
  if (!vision) return;
  const width = number(vision.frame_width);
  const height = number(vision.frame_height);
  const centerX = vision.center_x == null ? null : number(vision.center_x);
  const centerY = vision.center_y == null ? null : number(vision.center_y);
  const state = String(vision.state || "HOLD");
  const stateNode = byId("tracking-state");

  stateNode.className = `state-pill ${state.toLowerCase().replaceAll("_", "-")}`;
  stateNode.textContent = state;
  text("direction", vision.direction || `${vision.command_x || "HOLD"}_${vision.command_y || "HOLD"}`);
  text(
    "target-summary",
    number(vision.target_count) > 0
      ? `${vision.target_count}개 선택 · ID ${(vision.target_ids || []).join(", ")}`
      : "선택 객체 없음",
  );
  text("frame-size", width && height ? `${width} × ${height}` : "— × —");
  text("frame-index", `FRAME ${vision.frame_index ?? "—"}`);
  text("frame-center", width && height ? `(${Math.round(width / 2)}, ${Math.round(height / 2)})` : "—");
  text(
    "object-center",
    centerX == null || centerY == null || !width || !height
      ? "—"
      : `(${Math.round(centerX * width)}, ${Math.round(centerY * height)})`,
  );
  text(
    "normalized-center",
    centerX == null || centerY == null
      ? "normalized —"
      : `normalized (${fixed(centerX, 3)}, ${fixed(centerY, 3)})`,
  );

  const errorX = number(vision.error_x);
  const errorY = number(vision.error_y);
  text("error-x", signed(errorX));
  text("error-y", signed(errorY));
  text("error-magnitude", Math.hypot(errorX, errorY).toFixed(3));
  updateErrorBar("error-x-bar", errorX);
  updateErrorBar("error-y-bar", errorY);
}

function percentFor(value, min, max) {
  if (max <= min) return 50;
  return clamp(((value - min) / (max - min)) * 100, 0, 100);
}

function updateAxis(axis, servo) {
  const current = number(servo[`${axis}_deg`]);
  const target = number(servo[`target_${axis}_deg`]);
  const min = number(servo[`${axis}_minimum_deg`], axis === "pan" ? -90 : 0);
  const max = number(servo[`${axis}_maximum_deg`], axis === "pan" ? 90 : 110);
  const pulse = servo[`${axis}_pulse_us`];

  text(`${axis}-angle`, fixed(current));
  text(`${axis}-target`, `${signed(target, 2)}°`);
  text(`${axis}-delta`, `Δ ${signed(target - current, 2)}°`);
  text(`${axis}-min`, `${signed(min, 0)}°`);
  text(`${axis}-max`, `${signed(max, 0)}°`);
  text(`${axis}-pulse`, pulse == null ? "— µs" : `${fixed(pulse, 1)} µs`);
  byId(`${axis}-current-marker`).style.left = `${percentFor(current, min, max)}%`;
  byId(`${axis}-target-marker`).style.left = `${percentFor(target, min, max)}%`;
}

function updateServo(servo) {
  if (!servo) return;
  updateAxis("pan", servo);
  updateAxis("tilt", servo);
  const enabled = Boolean(servo.hardware_enabled);
  text("hardware-icon", enabled ? "●" : "○");
  text("hardware-label", enabled ? "실제 출력 활성" : "DRY-RUN");
  text(
    "hardware-description",
    enabled ? "PCA9685에 PWM을 출력 중입니다." : "각도만 계산하며 모터에는 출력하지 않습니다.",
  );
  byId("hardware-icon").style.color = enabled ? "var(--green)" : "var(--amber)";
  text("servo-state", servo.state || "—");
  text("accepted-messages", servo.accepted_messages ?? "—");
  text("rejected-messages", servo.rejected_messages ?? "—");
  text("timeout-holds", servo.timeout_holds ?? "—");
}

function updateLaughter(laughter) {
  if (!laughter) return;
  const status = String(laughter.upload_status || laughter.state || "DETECTED");
  const statusNode = byId("laughter-status");
  statusNode.className = `state-pill laughter-${status.toLowerCase().replaceAll("_", "-")}`;
  statusNode.textContent = status;
  text("laughter-time", formatTime(laughter.occurred_at || laughter.updated_at));
  text(
    "laughter-confidence",
    laughter.confidence == null ? "—" : fixed(laughter.confidence, 3),
  );
  text("laughter-event-id", laughter.event_id || "—");
  text("laughter-video-id", laughter.video_id || "—");
  const retry = laughter.attempts
    ? ` · ${laughter.attempts}회차${laughter.retry_delay_seconds ? ` / ${laughter.retry_delay_seconds}초 후` : ""}`
    : "";
  text("laughter-detail", `${laughter.detail || status}${retry}`);
}

function updateYamnet(yamnet) {
  if (!yamnet) return;
  const status = String(yamnet.status || "READY").toUpperCase();
  const ready = status === "READY";
  text(
    "yamnet-status",
    yamnet.detail ? `${status} · ${yamnet.detail}` : status,
  );
  if (!ready) {
    text("yamnet-score", "—");
    text("yamnet-rms", "—");
    text("yamnet-top-class", "—");
    text("yamnet-streak", "—");
    text("yamnet-inference", "—");
  }
  const score = number(yamnet.score);
  const threshold = number(yamnet.threshold);
  if (ready) text("yamnet-score", fixed(score, 3));
  text(
    "yamnet-threshold",
    `${yamnet.aggregation || "mean"} ≥ ${fixed(threshold, 3)}`,
  );
  if (ready) {
    text("yamnet-rms", fixed(yamnet.rms, 4));
    text(
      "yamnet-top-class",
      yamnet.top_class
        ? `${yamnet.top_class} (${fixed(yamnet.top_score, 3)})`
        : "—",
    );
    text(
      "yamnet-streak",
      `${yamnet.positive_streak ?? 0}${yamnet.would_trigger ? " · TRIGGER" : ""}`,
    );
    text(
      "yamnet-inference",
      yamnet.inference_ms == null ? "—" : `${fixed(yamnet.inference_ms, 0)} ms`,
    );
  }
}

function formatTime(value) {
  if (!value) return "—";
  return new Intl.DateTimeFormat("ko-KR", {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    fractionalSecondDigits: 1,
    hour12: false,
  }).format(new Date(value));
}

function renderEvents(events) {
  latestEvents = events;
  if (logPaused) return;
  const rows = byId("event-rows");
  if (!events.length) {
    rows.innerHTML = '<tr class="empty-row"><td colspan="7">텔레메트리 대기 중</td></tr>';
    return;
  }
  rows.replaceChildren(
    ...events.slice(-80).reverse().map((event) => {
      const row = document.createElement("tr");
      row.dataset.source = event.source;
      const laughter = event.source === "laughter";
      const values = laughter
        ? [
            formatTime(event.recorded_at),
            "LAUGHTER",
            event.upload_status || event.state || "DETECTED",
            event.event_id || "—",
            event.confidence == null ? "—" : fixed(event.confidence, 3),
            event.http_status == null ? "—" : `HTTP ${event.http_status}`,
            event.video_id || event.detail || "—",
          ]
        : [
            formatTime(event.recorded_at),
            event.source.toUpperCase(),
            [event.state, event.direction || `${event.command_x || ""} ${event.command_y || ""}`]
              .filter(Boolean).join(" · "),
            event.center_x == null ? "—" : `${fixed(event.center_x, 3)}, ${fixed(event.center_y, 3)}`,
            event.error_x == null ? "—" : `${signed(event.error_x)} · ${signed(event.error_y)}`,
            event.pan_deg == null ? "—" : `${signed(event.pan_deg, 2)}°`,
            event.tilt_deg == null ? "—" : `${signed(event.tilt_deg, 2)}°`,
          ];
      values.forEach((value) => {
        const cell = document.createElement("td");
        cell.textContent = value;
        row.appendChild(cell);
      });
      return row;
    }),
  );
}

function chartSeries(events) {
  const merged = [];
  let pan = 0;
  let tilt = 0;
  let error = 0;
  for (const event of events.slice(-120)) {
    if (event.pan_deg != null) pan = number(event.pan_deg);
    if (event.tilt_deg != null) tilt = number(event.tilt_deg);
    if (event.error_x != null) error = Math.hypot(number(event.error_x), number(event.error_y)) * 10;
    merged.push({ pan, tilt, error });
  }
  return merged.slice(-60);
}

function drawChart(events) {
  const canvas = byId("movement-chart");
  const rect = canvas.getBoundingClientRect();
  const ratio = window.devicePixelRatio || 1;
  canvas.width = Math.max(1, Math.round(rect.width * ratio));
  canvas.height = Math.max(1, Math.round(rect.height * ratio));
  const ctx = canvas.getContext("2d");
  ctx.scale(ratio, ratio);
  const width = rect.width;
  const height = rect.height;
  const pad = { left: 34, right: 12, top: 10, bottom: 24 };
  const plotWidth = width - pad.left - pad.right;
  const plotHeight = height - pad.top - pad.bottom;
  const data = chartSeries(events);

  ctx.clearRect(0, 0, width, height);
  ctx.strokeStyle = "rgba(121, 146, 163, 0.18)";
  ctx.fillStyle = "#7992a3";
  ctx.font = "10px ui-monospace";
  [-10, 0, 10].forEach((tick) => {
    const y = pad.top + ((15 - tick) / 30) * plotHeight;
    ctx.beginPath();
    ctx.moveTo(pad.left, y);
    ctx.lineTo(width - pad.right, y);
    ctx.stroke();
    ctx.fillText(`${tick}°`, 3, y + 3);
  });
  if (data.length < 2) return;

  const colors = { pan: "#51d7e8", tilt: "#ffbd66", error: "#ff657a" };
  Object.keys(colors).forEach((key) => {
    ctx.strokeStyle = colors[key];
    ctx.lineWidth = 2;
    ctx.beginPath();
    data.forEach((point, index) => {
      const x = pad.left + (index / Math.max(1, data.length - 1)) * plotWidth;
      const y = pad.top + ((15 - clamp(point[key], -15, 15)) / 30) * plotHeight;
      if (index === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
    });
    ctx.stroke();
  });
}

async function refresh() {
  try {
    const response = await fetch("/api/state", { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const payload = await response.json();
    lastSuccessAt = Date.now();
    setConnection(true, "실시간 연결");
    text("server-time", formatTime(payload.server_time));
    text("dashboard-uptime", `시작 시간 ${formatTime(payload.started_at)}`);
    updateVision(payload.vision);
    updateServo(payload.servo);
    updateYamnet(payload.yamnet);
    updateLaughter(payload.laughter);
    renderEvents(payload.events || []);
    drawChart(payload.events || []);
    if (payload.frame_sequence > 0) byId("video-empty").hidden = true;
  } catch {
    if (Date.now() - lastSuccessAt > 2500) setConnection(false, "연결 끊김");
  }
}

byId("pause-log").addEventListener("click", () => {
  logPaused = !logPaused;
  byId("pause-log").classList.toggle("active", logPaused);
  text("pause-log", logPaused ? "계속 보기" : "일시정지");
  if (!logPaused) renderEvents(latestEvents);
});

byId("download-log").addEventListener("click", () => {
  const blob = new Blob([JSON.stringify(latestEvents, null, 2)], { type: "application/json" });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = `edge-telemetry-${new Date().toISOString().replaceAll(":", "-")}.json`;
  link.click();
  URL.revokeObjectURL(url);
});

window.addEventListener("resize", () => drawChart(latestEvents));
refresh();
setInterval(refresh, 500);
