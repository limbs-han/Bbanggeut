"use client";

import { ChangeEvent, useEffect, useMemo, useState } from "react";

type TabId = "overview" | "vision" | "audio" | "timeline";
type ChartMode = "fps" | "latency";
type Snapshot = {
  schemaVersion: string;
  collectedAt: string;
  source: string;
  runId: string;
  system: {
    ramUsedMb: number | null;
    ramTotalMb: number | null;
    gpuPercent: number | null;
    temperatureC: number | null;
    powerMw: number | null;
  };
  vision: {
    fps: number | null;
    frameCount: number | null;
    state: string;
    command: string;
    targetCount: number | null;
    stableObjectCount: number | null;
  };
  audio: {
    model: string;
    selectedScore: number | null;
    selectedClass: string | null;
    topClass: string | null;
    latencyMeanMs: number | null;
    latencyP95Ms: number | null;
    sampleCount: number;
  };
  events: Array<{
    eventId: string;
    eventType: string | null;
    observedAt: string | null;
    confidence: number | null;
    className: string | null;
  }>;
  comparisons: Array<{
    runId: string | null;
    createdAt: string | null;
    component: string;
    model: string | null;
    runtime: string | null;
    dataset: string | null;
    metrics: {
      fps?: number | null;
      wallMeanMs?: number | null;
      inferenceMeanMs?: number | null;
      memoryMb?: number | null;
    };
  }>;
};

const navItems: Array<{ id: TabId; label: string; count: string }> = [
  { id: "overview", label: "운영 개요", count: "01" },
  { id: "vision", label: "비전 비교", count: "03" },
  { id: "audio", label: "오디오 비교", count: "03" },
  { id: "timeline", label: "이벤트 타임라인", count: "12" },
];

const visionModels = [
  {
    name: "YOLOv8n",
    runtime: "TensorRT FP16",
    fps: 28.4,
    latency: 31.8,
    map: 37.3,
    memory: 812,
    score: 82,
    dot: "",
  },
  {
    name: "YOLO11n",
    runtime: "TensorRT FP16",
    fps: 31.7,
    latency: 28.2,
    map: 39.5,
    memory: 768,
    score: 91,
    dot: "blue",
  },
  {
    name: "YOLO26n",
    runtime: "PyTorch FP16",
    fps: 22.9,
    latency: 40.6,
    map: 40.9,
    memory: 946,
    score: 86,
    dot: "purple",
  },
];

const audioModels = [
  {
    name: "YAMNet",
    note: "현재 기준선. AudioSet 521개 클래스로 웃음·박수 후보를 빠르게 확인합니다.",
    f1: "0.82",
    latency: "54 ms",
    memory: "641 MB",
    recommended: true,
  },
  {
    name: "EfficientAT MN10",
    note: "경량 AudioSet 모델. Jetson 지연시간과 분류 성능의 균형을 비교합니다.",
    f1: "—",
    latency: "측정 전",
    memory: "측정 전",
    recommended: false,
  },
  {
    name: "PANNs CNN10",
    note: "강한 오디오 분류 기준선. 무거운 대신 어려운 환경의 재현율을 확인합니다.",
    f1: "—",
    latency: "측정 전",
    memory: "측정 전",
    recommended: false,
  },
];

const eventRows = [
  {
    time: "14:22:38.190",
    title: "웃음 세션 시작",
    detail: "YAMNet · confidence 0.84",
    tag: "LAUGHTER",
    kind: "laughter",
  },
  {
    time: "14:22:45.520",
    title: "연속 박수 후보",
    detail: "2회 / 1.36초",
    tag: "CLAP ×2",
    kind: "clap",
  },
  {
    time: "14:22:56.041",
    title: "호출명 감지 후보",
    detail: "“윌리엄” · speaker agnostic",
    tag: "WAKE NAME",
    kind: "wake",
  },
  {
    time: "14:23:08.661",
    title: "동일 세션으로 병합",
    detail: "gap 12.62초 · 최대 5분",
    tag: "MERGED",
    kind: "",
  },
];

function buildSeries(seed: number, count = 34) {
  return Array.from({ length: count }, (_, index) => {
    const wave = Math.sin((index + seed) / 3.2) * 3.1;
    const ripple = Math.cos((index + seed) / 1.45) * 1.2;
    return 28 + wave + ripple;
  });
}

function toPolyline(values: number[], min: number, max: number) {
  return values
    .map((value, index) => {
      const x = (index / (values.length - 1)) * 100;
      const y = 100 - ((value - min) / (max - min)) * 100;
      return `${x.toFixed(2)},${Math.max(0, Math.min(100, y)).toFixed(2)}`;
    })
    .join(" ");
}

export function BenchmarkDashboard() {
  const [activeTab, setActiveTab] = useState<TabId>("overview");
  const [chartMode, setChartMode] = useState<ChartMode>("fps");
  const [tick, setTick] = useState(0);
  const [toast, setToast] = useState("");
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [collectorState, setCollectorState] = useState<
    "connecting" | "live" | "demo"
  >("connecting");

  useEffect(() => {
    const timer = window.setInterval(() => setTick((value) => value + 1), 1800);
    return () => window.clearInterval(timer);
  }, []);

  useEffect(() => {
    const endpoint =
      process.env.NEXT_PUBLIC_BENCHMARK_API ??
      "http://127.0.0.1:8765/api/snapshot";
    let stopped = false;

    async function refresh() {
      try {
        const response = await fetch(endpoint, {
          cache: "no-store",
          signal: AbortSignal.timeout(1400),
        });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const nextSnapshot = (await response.json()) as Snapshot;
        if (stopped || nextSnapshot.schemaVersion !== "0.1") return;
        setSnapshot(nextSnapshot);
        setCollectorState("live");
      } catch {
        if (!stopped) setCollectorState("demo");
      }
    }

    void refresh();
    const timer = window.setInterval(refresh, 2000);
    return () => {
      stopped = true;
      window.clearInterval(timer);
    };
  }, []);

  useEffect(() => {
    if (!toast) return;
    const timer = window.setTimeout(() => setToast(""), 3600);
    return () => window.clearTimeout(timer);
  }, [toast]);

  const fps = snapshot?.vision.fps ?? 29.4 + Math.sin(tick / 2) * 1.2;
  const latency =
    snapshot?.audio.latencyMeanMs ?? 33.7 + Math.cos(tick / 2.4) * 2.3;
  const temperature =
    snapshot?.system.temperatureC ?? 51 + Math.sin(tick / 4) * 2;
  const gpuPercent =
    snapshot?.system.gpuPercent ?? 64 + Math.sin(tick / 3) * 4;
  const memoryUsedGb =
    snapshot?.system.ramUsedMb != null
      ? snapshot.system.ramUsedMb / 1024
      : 4.8;
  const memoryDetail =
    snapshot?.system.ramTotalMb != null &&
    snapshot.system.ramUsedMb != null
      ? `총 ${(snapshot.system.ramTotalMb / 1024).toFixed(1)} GB 중 ${(
          (snapshot.system.ramUsedMb / snapshot.system.ramTotalMb) *
          100
        ).toFixed(0)}%`
      : "총 7.4 GB 중 65%";
  const seriesA = useMemo(() => buildSeries(tick % 8), [tick]);
  const seriesB = useMemo(
    () => buildSeries((tick + 4) % 11).map((value) => value + 3.1),
    [tick],
  );

  const chartA =
    chartMode === "fps"
      ? toPolyline(seriesA, 18, 38)
      : toPolyline(seriesA.map((value) => 62 - value), 24, 45);
  const chartB =
    chartMode === "fps"
      ? toPolyline(seriesB, 18, 38)
      : toPolyline(seriesB.map((value) => 60 - value), 24, 45);
  const displayedVisionModels = visionModels.map((candidate) => {
    const measured = snapshot?.comparisons?.find(
      (row) =>
        row.component === "vision" &&
        row.model?.toLowerCase() === candidate.name.toLowerCase(),
    );
    if (!measured) return candidate;
    return {
      ...candidate,
      runtime: measured.runtime ?? candidate.runtime,
      fps: measured.metrics.fps ?? candidate.fps,
      latency:
        measured.metrics.inferenceMeanMs ??
        measured.metrics.wallMeanMs ??
        candidate.latency,
      memory: measured.metrics.memoryMb ?? candidate.memory,
    };
  });

  async function handleImport(event: ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0];
    if (!file) return;

    try {
      const text = await file.text();
      const rows = text
        .split(/\r?\n/)
        .filter((line) => line.trim())
        .map((line) => JSON.parse(line));
      setToast(`${file.name} · ${rows.length}개 JSONL 레코드를 읽었습니다.`);
    } catch {
      setToast("JSONL을 읽지 못했습니다. 한 줄에 JSON 객체 하나인지 확인하세요.");
    } finally {
      event.target.value = "";
    }
  }

  return (
    <div className="app-shell">
      <header className="topbar">
        <div className="brand">
          <div className="brand-mark" aria-hidden="true">
            WJ
          </div>
          <div className="brand-copy">
            <strong>Edge Observatory</strong>
            <span>Jetson Orin Nano · model benchmark console</span>
          </div>
        </div>

        <div className="topbar-actions">
          <span className="source-chip mono">BRIO 100 / 1280×720</span>
          <span className="privacy-chip">LAN 전용</span>
          <span className="live-chip">
            <span className="live-dot" aria-hidden="true" />
            {collectorState === "live"
              ? "Jetson 실측 연결"
              : collectorState === "connecting"
                ? "수집기 연결 중"
                : "데모 스냅샷"}
          </span>
          <label className="import-button">
            <span aria-hidden="true">＋</span> JSONL 가져오기
            <input
              type="file"
              accept=".jsonl,.ndjson,application/x-ndjson,application/json"
              onChange={handleImport}
            />
          </label>
        </div>
      </header>

      <div className="workspace">
        <aside className="sidebar">
          <p className="nav-label">Workspace</p>
          <nav className="nav-list" aria-label="대시보드 화면">
            {navItems.map((item) => (
              <button
                className={`nav-button ${activeTab === item.id ? "active" : ""}`}
                key={item.id}
                type="button"
                onClick={() => setActiveTab(item.id)}
                aria-current={activeTab === item.id ? "page" : undefined}
              >
                <span>{item.label}</span>
                <span>{item.count}</span>
              </button>
            ))}
          </nav>

          <div className="sidebar-note">
            <strong>데이터 보존 원칙</strong>
            원본 영상·음성은 Jetson 내부에 유지하고, 대시보드에는 성능 수치와
            비식별 이벤트 메타데이터만 표시합니다.
          </div>
        </aside>

        <main className="main">
          <section className="hero">
            <div>
              <p className="eyebrow">Experiment / live snapshot</p>
              <h1>
                가장 빠른 모델보다
                <br />
                <em>가장 설명 가능한 선택.</em>
              </h1>
            </div>
            <dl className="hero-meta mono">
              <dt>RUN</dt>
              <dd>#{snapshot?.runId ?? "WJ-0730-014"}</dd>
              <dt>PROFILE</dt>
              <dd>MAXN · 15W</dd>
              <dt>UPDATED</dt>
              <dd>
                {snapshot?.collectedAt?.slice(11, 19) ??
                  (collectorState === "connecting" ? "CONNECTING" : "DEMO")}
              </dd>
            </dl>
          </section>

          <section className="metric-grid" aria-label="실시간 핵심 지표">
            <Metric
              label="Inference FPS"
              value={fps.toFixed(1)}
              unit="FPS"
              detail="30 FPS 입력 · drop 0.3%"
              accent
            />
            <Metric
              label="Mean latency"
              value={latency.toFixed(1)}
              unit="ms"
              detail="p95 47.2 ms"
            />
            <Metric
              label="GPU usage"
              value={gpuPercent.toFixed(0)}
              unit="%"
              detail="Orin CUDA · 612 MHz"
            />
            <Metric
              label="Memory"
              value={memoryUsedGb.toFixed(1)}
              unit="GB"
              detail={memoryDetail}
            />
            <Metric
              label="Temperature"
              value={temperature.toFixed(0)}
              unit="°C"
              detail="스로틀링 없음"
              warn={temperature > 54}
            />
          </section>

          <div className="dashboard-grid">
            <div className="stack">
              {(activeTab === "overview" || activeTab === "vision") && (
                <>
                  <section className="panel">
                    <div className="panel-header">
                      <div className="panel-title">
                        <h2>실시간 추론 성능</h2>
                        <span>최근 60초</span>
                      </div>
                      <div className="segmented" aria-label="차트 지표">
                        <button
                          type="button"
                          className={chartMode === "fps" ? "active" : ""}
                          onClick={() => setChartMode("fps")}
                        >
                          FPS
                        </button>
                        <button
                          type="button"
                          className={chartMode === "latency" ? "active" : ""}
                          onClick={() => setChartMode("latency")}
                        >
                          지연시간
                        </button>
                      </div>
                    </div>
                    <div className="chart-area">
                      <div className="chart-legend">
                        <span>
                          <i className="legend-line" /> YOLOv8n / active
                        </span>
                        <span>
                          <i className="legend-line blue" /> YOLO11n / reference
                        </span>
                      </div>
                      <svg
                        className="performance-chart"
                        viewBox="0 0 100 100"
                        preserveAspectRatio="none"
                        role="img"
                        aria-label={`${chartMode === "fps" ? "초당 프레임" : "추론 지연시간"} 변화 차트`}
                      >
                        <polyline
                          points={chartB}
                          fill="none"
                          stroke="#248cc1"
                          strokeWidth="1.1"
                          vectorEffect="non-scaling-stroke"
                        />
                        <polyline
                          points={chartA}
                          fill="none"
                          stroke="#e45a45"
                          strokeWidth="1.8"
                          vectorEffect="non-scaling-stroke"
                        />
                      </svg>
                    </div>
                  </section>

                  <section className="panel">
                    <div className="panel-header">
                      <div className="panel-title">
                        <h2>YOLO 후보 비교</h2>
                        <span>동일 데이터셋 · 동일 전력 모드</span>
                      </div>
                      <span className="mono" style={{ fontSize: "0.63rem" }}>
                        3 / 6 RUNS
                      </span>
                    </div>
                    <div className="comparison-wrap">
                      <table className="comparison-table">
                        <thead>
                          <tr>
                            <th>모델 / 런타임</th>
                            <th>FPS ↑</th>
                            <th>Latency ↓</th>
                            <th>COCO mAP</th>
                            <th>RAM</th>
                            <th>종합</th>
                          </tr>
                        </thead>
                        <tbody>
                          {displayedVisionModels.map((model) => (
                            <tr
                              key={model.name}
                              className={model.name === "YOLO11n" ? "selected" : ""}
                            >
                              <td>
                                <div className="model-cell">
                                  <i className={`model-dot ${model.dot}`} />
                                  <span>
                                    <strong>{model.name}</strong>
                                    <br />
                                    <small>{model.runtime}</small>
                                  </span>
                                </div>
                              </td>
                              <td className="mono">{model.fps}</td>
                              <td className="mono">{model.latency} ms</td>
                              <td className="mono">{model.map}</td>
                              <td className="mono">{model.memory} MB</td>
                              <td>
                                <span
                                  className={`score ${model.score === 91 ? "best" : ""}`}
                                >
                                  {model.score}
                                </span>
                              </td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    </div>
                  </section>
                </>
              )}

              {activeTab === "audio" && (
                <section className="panel">
                  <div className="panel-header">
                    <div className="panel-title">
                      <h2>오디오 모델 비교 계획</h2>
                      <span>웃음 · 연속 박수 · 호출명 · 일반 음성</span>
                    </div>
                    <span className="mono" style={{ fontSize: "0.63rem" }}>
                      LOCAL AUDIO ONLY
                    </span>
                  </div>
                  <div className="audio-grid">
                    {audioModels.map((model) => (
                      <article
                        className={`audio-model ${model.recommended ? "recommended" : ""}`}
                        key={model.name}
                      >
                        <h3>{model.name}</h3>
                        <p>{model.note}</p>
                        <div className="audio-stat">
                          <span>macro F1</span>
                          <strong>{model.f1}</strong>
                        </div>
                        <div className="audio-stat">
                          <span>mean latency</span>
                          <strong>{model.latency}</strong>
                        </div>
                        <div className="audio-stat">
                          <span>peak RSS</span>
                          <strong>{model.memory}</strong>
                        </div>
                      </article>
                    ))}
                  </div>
                </section>
              )}

              {(activeTab === "overview" || activeTab === "timeline") && (
                <section className="panel">
                  <div className="panel-header">
                    <div className="panel-title">
                      <h2>통합 이벤트 세션</h2>
                      <span>30초 병합 윈도우 · 최대 5분</span>
                    </div>
                    <span className="mono" style={{ fontSize: "0.63rem" }}>
                      14:22:30 — 14:23:30
                    </span>
                  </div>
                  <div className="timeline-ruler" aria-label="통합 이벤트 타임라인">
                    <div className="timeline-track objects">
                      <span className="timeline-label">OBJECTS</span>
                      <i
                        className="timeline-segment"
                        style={{ left: "14%", width: "26%" }}
                      />
                      <i
                        className="timeline-segment"
                        style={{ left: "47%", width: "32%" }}
                      />
                    </div>
                    <div className="timeline-track audio">
                      <span className="timeline-label">AUDIO</span>
                      <i
                        className="timeline-segment"
                        style={{ left: "22%", width: "17%" }}
                      />
                      <i
                        className="timeline-segment"
                        style={{ left: "44%", width: "9%" }}
                      />
                      <i
                        className="timeline-segment"
                        style={{ left: "62%", width: "12%" }}
                      />
                    </div>
                    <div className="timeline-track system">
                      <span className="timeline-label">SESSION</span>
                      <i
                        className="timeline-segment"
                        style={{ left: "22%", width: "58%" }}
                      />
                    </div>
                  </div>
                </section>
              )}
            </div>

            <aside className="stack">
              <section className="panel">
                <div className="panel-header">
                  <div className="panel-title">
                    <h2>현재 실험</h2>
                    <span>RUNNING</span>
                  </div>
                  <span className="experiment-format">TRT FP16</span>
                </div>
                <div className="experiment-card">
                  <div className="experiment-top">
                    <div>
                      <p className="eyebrow">Vision candidate</p>
                      <p className="experiment-model">YOLO11n</p>
                    </div>
                    <span className="score best">추천</span>
                  </div>
                  <div className="progress-track">
                    <div className="progress-fill" />
                  </div>
                  <div className="progress-meta mono">
                    <span>864 / 1,200 frames</span>
                    <span>72%</span>
                  </div>
                  <div className="experiment-config">
                    <div className="config-item">
                      <span>Dataset</span>
                      <strong>office-mix-v1</strong>
                    </div>
                    <div className="config-item">
                      <span>Power mode</span>
                      <strong>MAXN · 15W</strong>
                    </div>
                    <div className="config-item">
                      <span>Resolution</span>
                      <strong>1280×720</strong>
                    </div>
                    <div className="config-item">
                      <span>Targets</span>
                      <strong>person / cat / dog</strong>
                    </div>
                  </div>
                </div>
              </section>

              <section className="panel">
                <div className="panel-header">
                  <div className="panel-title">
                    <h2>파이프라인 상태</h2>
                    <span>6 / 6 HEALTHY</span>
                  </div>
                </div>
                <div className="stage-list">
                  {[
                    ["01", "BRIO 100 입력", "video + mono audio", "30 FPS"],
                    ["02", "MediaMTX 로컬", "homecam/ai", "ONLINE"],
                    ["03", "YOLO 추론", "group-center tracking", "29.4 FPS"],
                    ["04", "오디오 추론", "YAMNet baseline", "54 ms"],
                    ["05", "이벤트 병합", "30s gap / 5m cap", "IDLE"],
                    ["06", "업로드 큐", "delete-after-upload", "0 pending"],
                  ].map(([index, title, detail, value]) => (
                    <div className="stage-row" key={index}>
                      <span className="stage-index ok">{index}</span>
                      <span className="stage-copy">
                        <strong>{title}</strong>
                        <span>{detail}</span>
                      </span>
                      <span className="stage-value">{value}</span>
                    </div>
                  ))}
                </div>
              </section>

              <section className="panel">
                <div className="panel-header">
                  <div className="panel-title">
                    <h2>최근 이벤트</h2>
                    <span>LOCAL METADATA</span>
                  </div>
                </div>
                <div className="event-list">
                  {eventRows.map((event) => (
                    <div className="event-row" key={`${event.time}-${event.tag}`}>
                      <span className="stage-index">•</span>
                      <span className="event-copy">
                        <strong>{event.title}</strong>
                        <span>{event.detail}</span>
                        <span className={`event-tag ${event.kind}`}>{event.tag}</span>
                      </span>
                      <span className="event-time">{event.time}</span>
                    </div>
                  ))}
                </div>
              </section>
            </aside>
          </div>

          <footer className="footer-note">
            <span>
              {collectorState === "live"
                ? "Jetson 읽기 전용 수집기에서 실측 데이터를 받고 있습니다."
                : "Jetson 수집기 연결 전에는 수치가 시뮬레이션됩니다."}
            </span>
            <span className="mono">SCHEMA v0.1 · REFRESH 1.8s</span>
          </footer>
        </main>
      </div>

      {toast && (
        <div className="toast" role="status">
          {toast}
        </div>
      )}
    </div>
  );
}

function Metric({
  label,
  value,
  unit,
  detail,
  accent = false,
  warn = false,
}: {
  label: string;
  value: string;
  unit: string;
  detail: string;
  accent?: boolean;
  warn?: boolean;
}) {
  const className = ["metric-card", accent ? "accent" : "", warn ? "warn" : ""]
    .filter(Boolean)
    .join(" ");

  return (
    <article className={className}>
      <div className="metric-label">
        <span>{label}</span>
        <span aria-hidden="true">↗</span>
      </div>
      <div className="metric-value">
        {value}
        <span className="metric-unit">{unit}</span>
      </div>
      <div className="metric-delta">{detail}</div>
    </article>
  );
}
