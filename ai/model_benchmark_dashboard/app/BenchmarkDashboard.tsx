"use client";

import { useEffect, useMemo, useState } from "react";
import type { ReactNode } from "react";

type TabId = "overview" | "vision" | "audio" | "timeline";
type ChartMode = "fps" | "latency";
type CollectorState = "connecting" | "live" | "partial" | "offline";
type SourceFreshness = {
  available: boolean;
  updatedAt: string | null;
  ageSeconds: number | null;
  stale: boolean;
};
type Snapshot = {
  schemaVersion: string;
  collectedAt: string;
  source: string;
  runId: string;
  runDirectory: string;
  freshness?: {
    available: boolean;
    latestSourceAt: string | null;
    ageSeconds: number | null;
    stale: boolean;
    staleAfterSeconds: number;
    sources: {
      resources?: SourceFreshness;
      vision?: SourceFreshness;
      audio?: SourceFreshness;
    };
  };
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
      wallP95Ms?: number | null;
      inferenceMeanMs?: number | null;
      inferenceP95Ms?: number | null;
      measuredFrames?: number | null;
      memoryMb?: number | null;
    };
    accuracy?: {
      status?: string;
      reason?: string;
    } | null;
  }>;
  benchmarkProgress?: {
    schemaVersion: string | null;
    runId: string | null;
    updatedAt: string | null;
    status: string | null;
    component: string | null;
    model: string | null;
    runtime: string | null;
    dataset: string | null;
    progress: {
      completedFrames?: number | null;
      totalFrames?: number | null;
      completedTasks?: number | null;
      totalTasks?: number | null;
      percent?: number | null;
    };
    current?: {
      repeat?: number | null;
      sampleId?: string | null;
    } | null;
  } | null;
};

type HistoryPoint = {
  collectedAt: string;
  fps: number | null;
  latency: number | null;
};

const audioCandidates = [
  {
    name: "YAMNet",
    note: "현재 운영 기준선입니다. 연결된 진단 JSONL이 있을 때만 지연시간과 표본 수를 표시합니다.",
  },
  {
    name: "EfficientAT MN10",
    note: "동일 평가 데이터셋에서 실행 결과가 생성되기 전까지 수치를 표시하지 않습니다.",
  },
  {
    name: "PANNs CNN10",
    note: "정답 라벨 기반 평가와 Jetson 성능 측정을 완료한 뒤 비교 결과에 포함합니다.",
  },
];

function formatNumber(
  value: number | null | undefined,
  digits = 1,
): string {
  return value == null || !Number.isFinite(value) ? "N/A" : value.toFixed(digits);
}

function formatTimestamp(value: string | null | undefined): string {
  if (!value) return "N/A";
  const parsed = new Date(value);
  if (Number.isNaN(parsed.getTime())) return "N/A";
  return parsed.toLocaleTimeString("ko-KR", {
    hour12: false,
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}

function formatAge(value: number | null | undefined): string {
  if (value == null || !Number.isFinite(value)) return "갱신 시각 없음";
  if (value < 1) return "방금 갱신";
  return `${Math.round(value)}초 전 갱신`;
}

function toPolyline(values: number[]): string {
  if (values.length < 2) return "";
  const minimum = Math.min(...values);
  const maximum = Math.max(...values);
  const range = Math.max(maximum - minimum, 1);
  return values
    .map((value, index) => {
      const x = (index / (values.length - 1)) * 100;
      const y = 92 - ((value - minimum) / range) * 84;
      return `${x.toFixed(2)},${y.toFixed(2)}`;
    })
    .join(" ");
}

function sourceState(
  source: SourceFreshness | undefined,
  inferredAvailable = false,
): {
  label: string;
  healthy: boolean;
  detail: string;
} {
  if (source === undefined && inferredAvailable) {
    return {
      label: "LIVE",
      healthy: true,
      detail: "값 수신 · freshness 미지원",
    };
  }
  if (!source?.available) {
    return { label: "NO DATA", healthy: false, detail: "파일 없음" };
  }
  if (source.stale) {
    return {
      label: "STALE",
      healthy: false,
      detail: formatAge(source.ageSeconds),
    };
  }
  return {
    label: "LIVE",
    healthy: true,
    detail: formatAge(source.ageSeconds),
  };
}

export function BenchmarkDashboard() {
  const [activeTab, setActiveTab] = useState<TabId>("overview");
  const [chartMode, setChartMode] = useState<ChartMode>("fps");
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [history, setHistory] = useState<HistoryPoint[]>([]);
  const [collectorState, setCollectorState] =
    useState<CollectorState>("connecting");

  useEffect(() => {
    const endpoint =
      process.env.NEXT_PUBLIC_BENCHMARK_API ??
      "http://127.0.0.1:8765/api/snapshot";
    let stopped = false;

    async function refresh() {
      try {
        const response = await fetch(endpoint, {
          cache: "no-store",
          signal: AbortSignal.timeout(1600),
        });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const nextSnapshot = (await response.json()) as Snapshot;
        if (stopped || nextSnapshot.schemaVersion !== "0.1") return;

        const coreValues = [
          nextSnapshot.vision.fps,
          nextSnapshot.system.gpuPercent,
          nextSnapshot.system.ramUsedMb,
          nextSnapshot.system.temperatureC,
        ];
        const hasCoreMetrics = coreValues.every((value) => value != null);
        const stale =
          nextSnapshot.freshness?.stale ??
          Date.now() - new Date(nextSnapshot.collectedAt).getTime() > 10_000;
        const criticalSourceIssue = [
          nextSnapshot.freshness?.sources.resources,
          nextSnapshot.freshness?.sources.vision,
        ].some(
          (source) =>
            source !== undefined && (!source.available || source.stale),
        );

        setSnapshot(nextSnapshot);
        setCollectorState(
          stale || criticalSourceIssue || !hasCoreMetrics
            ? "partial"
            : "live",
        );
        setHistory((previous) => {
          if (
            previous.at(-1)?.collectedAt === nextSnapshot.collectedAt
          ) {
            return previous;
          }
          return [
            ...previous,
            {
              collectedAt: nextSnapshot.collectedAt,
              fps: nextSnapshot.vision.fps,
              latency: nextSnapshot.audio.latencyMeanMs,
            },
          ].slice(-30);
        });
      } catch {
        if (!stopped) setCollectorState("offline");
      }
    }

    void refresh();
    const timer = window.setInterval(refresh, 2000);
    return () => {
      stopped = true;
      window.clearInterval(timer);
    };
  }, []);

  const collectorLabel = {
    connecting: "수집기 연결 중",
    live: "Jetson 실측 LIVE",
    partial: "부분 데이터 PARTIAL",
    offline: "수집기 OFFLINE",
  }[collectorState];
  const comparisons =
    snapshot?.comparisons.filter((row) => row.component === "vision") ?? [];
  const events = snapshot?.events ?? [];
  const benchmarkProgress = snapshot?.benchmarkProgress ?? null;
  const progressPercent = benchmarkProgress?.progress.percent ?? null;
  const resourceSource = sourceState(
    snapshot?.freshness?.sources.resources,
    snapshot != null &&
      Object.values(snapshot.system).some((value) => value != null),
  );
  const visionSource = sourceState(
    snapshot?.freshness?.sources.vision,
    snapshot?.vision.frameCount != null || snapshot?.vision.fps != null,
  );
  const audioSource = sourceState(
    snapshot?.freshness?.sources.audio,
    (snapshot?.audio.sampleCount ?? 0) > 0,
  );
  const chartValues = useMemo(
    () =>
      history
        .map((point) =>
          chartMode === "fps" ? point.fps : point.latency,
        )
        .filter((value): value is number => value != null),
    [chartMode, history],
  );
  const chartPoints = useMemo(() => toPolyline(chartValues), [chartValues]);
  const memoryUsedGb =
    snapshot?.system.ramUsedMb != null
      ? snapshot.system.ramUsedMb / 1024
      : null;
  const memoryDetail =
    snapshot?.system.ramTotalMb != null &&
    snapshot.system.ramUsedMb != null
      ? `총 ${(snapshot.system.ramTotalMb / 1024).toFixed(1)} GB 중 ${(
          (snapshot.system.ramUsedMb / snapshot.system.ramTotalMb) *
          100
        ).toFixed(0)}%`
      : "리소스 로그 대기";
  const navItems: Array<{ id: TabId; label: string; count: string }> = [
    { id: "overview", label: "운영 개요", count: collectorState.toUpperCase() },
    { id: "vision", label: "비전 비교", count: String(comparisons.length) },
    {
      id: "audio",
      label: "오디오 비교",
      count: String(snapshot?.audio.sampleCount ?? 0),
    },
    { id: "timeline", label: "이벤트 타임라인", count: String(events.length) },
  ];

  const pipelineRows = [
    {
      index: "01",
      title: "수집기 API",
      detail:
        collectorState === "offline"
          ? "HTTP 응답 없음"
          : snapshot?.freshness?.ageSeconds != null
            ? formatAge(snapshot.freshness.ageSeconds)
            : snapshot
              ? "응답 수신"
              : "갱신 시각 없음",
      value: collectorState.toUpperCase(),
      healthy: collectorState === "live",
    },
    {
      index: "02",
      title: "Jetson 리소스 로그",
      detail: resourceSource.detail,
      value: resourceSource.label,
      healthy: resourceSource.healthy,
    },
    {
      index: "03",
      title: "YOLO 운영 로그",
      detail:
        snapshot?.vision.frameCount != null
          ? `${snapshot.vision.frameCount.toLocaleString()} frames`
          : visionSource.detail,
      value: visionSource.label,
      healthy: visionSource.healthy,
    },
    {
      index: "04",
      title: "YAMNet 진단 JSONL",
      detail:
        snapshot?.audio.sampleCount
          ? `${snapshot.audio.sampleCount} samples`
          : audioSource.detail,
      value: audioSource.label,
      healthy: audioSource.healthy,
    },
    {
      index: "05",
      title: "모델 비교 결과",
      detail: "summary.json",
      value: comparisons.length ? `${comparisons.length} RUNS` : "NO DATA",
      healthy: comparisons.length > 0,
    },
    {
      index: "06",
      title: "이벤트 메타데이터",
      detail: "*.trigger.json",
      value: events.length ? `${events.length} EVENTS` : "NO DATA",
      healthy: events.length > 0,
    },
  ];

  return (
    <div className="app-shell">
      <header className="topbar">
        <div className="brand">
          <div className="brand-mark" aria-hidden="true">
            WJ
          </div>
          <div className="brand-copy">
            <strong>Edge Observatory</strong>
            <span>Jetson Orin Nano · measured benchmark console</span>
          </div>
        </div>

        <div className="topbar-actions">
          <span className="source-chip mono">JETSON LOCAL</span>
          <span className="privacy-chip">LAN 전용</span>
          <span className={`live-chip ${collectorState}`}>
            <span className="live-dot" aria-hidden="true" />
            {collectorLabel}
          </span>
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
            <strong>실측 데이터 원칙</strong>
            원본 영상·음성은 Jetson 내부에 유지합니다. 수집되지 않은 값은
            추정하거나 보간하지 않고 N/A로 표시합니다.
          </div>
        </aside>

        <main className="main">
          <section className="hero">
            <div>
              <p className="eyebrow">Experiment / measured snapshot</p>
              <h1>
                가장 빠른 모델보다
                <br />
                <em>가장 설명 가능한 선택.</em>
              </h1>
            </div>
            <dl className="hero-meta mono">
              <dt>RUN</dt>
              <dd>#{snapshot?.runId || "N/A"}</dd>
              <dt>PROFILE</dt>
              <dd>미수집</dd>
              <dt>UPDATED</dt>
              <dd>{formatTimestamp(snapshot?.collectedAt)}</dd>
            </dl>
          </section>

          <section className="metric-grid" aria-label="실시간 핵심 지표">
            <Metric
              label="Vision FPS"
              value={formatNumber(snapshot?.vision.fps)}
              unit="FPS"
              detail={
                snapshot?.vision.frameCount != null
                  ? `${snapshot.vision.frameCount.toLocaleString()} frames`
                  : "YOLO 로그 대기"
              }
              accent={snapshot?.vision.fps != null}
            />
            <Metric
              label="Audio mean latency"
              value={formatNumber(snapshot?.audio.latencyMeanMs)}
              unit="ms"
              detail={
                snapshot?.audio.latencyP95Ms != null
                  ? `p95 ${snapshot.audio.latencyP95Ms.toFixed(1)} ms`
                  : "YAMNet 진단 JSONL 대기"
              }
            />
            <Metric
              label="GPU usage"
              value={formatNumber(snapshot?.system.gpuPercent, 0)}
              unit="%"
              detail={
                snapshot?.system.powerMw != null
                  ? `보드 전력 ${(snapshot.system.powerMw / 1000).toFixed(2)} W`
                  : "tegrastats 대기"
              }
            />
            <Metric
              label="Memory"
              value={formatNumber(memoryUsedGb)}
              unit="GB"
              detail={memoryDetail}
            />
            <Metric
              label="Temperature"
              value={formatNumber(snapshot?.system.temperatureC, 0)}
              unit="°C"
              detail="tegrastats 최고 센서값"
            />
          </section>

          <div className="dashboard-grid">
            <div className="stack">
              {(activeTab === "overview" || activeTab === "vision") && (
                <>
                  <section className="panel">
                    <div className="panel-header">
                      <div className="panel-title">
                        <h2>실시간 실측 추이</h2>
                        <span>브라우저 연결 이후 최대 30개 표본</span>
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
                          오디오 지연시간
                        </button>
                      </div>
                    </div>
                    <div className="chart-area">
                      {chartPoints ? (
                        <>
                          <div className="chart-legend">
                            <span>
                              <i className="legend-line" />
                              {chartMode === "fps"
                                ? "YOLO 운영 FPS"
                                : "YAMNet 평균 지연시간"}
                            </span>
                            <span className="mono">
                              {chartValues.length} measured samples
                            </span>
                          </div>
                          <svg
                            className="performance-chart"
                            viewBox="0 0 100 100"
                            preserveAspectRatio="none"
                            role="img"
                            aria-label={`실측 ${chartMode === "fps" ? "초당 프레임" : "오디오 지연시간"} 변화 차트`}
                          >
                            <polyline
                              points={chartPoints}
                              fill="none"
                              stroke="#e45a45"
                              strokeWidth="1.8"
                              vectorEffect="non-scaling-stroke"
                            />
                          </svg>
                        </>
                      ) : (
                        <EmptyState>
                          실측 표본이 2개 이상 쌓이면 차트를 표시합니다.
                        </EmptyState>
                      )}
                    </div>
                  </section>

                  <section className="panel">
                    <div className="panel-header">
                      <div className="panel-title">
                        <h2>YOLO 실측 결과 비교</h2>
                        <span>summary.json에 저장된 완료 결과만 표시</span>
                      </div>
                      <span className="mono result-count">
                        {comparisons.length} RUNS
                      </span>
                    </div>
                    <div className="comparison-wrap">
                      <table className="comparison-table">
                        <thead>
                          <tr>
                            <th>모델 / 런타임</th>
                            <th>데이터셋</th>
                            <th>FPS ↑</th>
                            <th>Inference mean ↓</th>
                            <th>Wall p95 ↓</th>
                            <th>Frames</th>
                            <th>정확도</th>
                          </tr>
                        </thead>
                        <tbody>
                          {comparisons.length ? (
                            comparisons.map((row, index) => (
                              <tr key={row.runId ?? `${row.model}-${index}`}>
                                <td>
                                  <div className="model-cell">
                                    <i className="model-dot" />
                                    <span>
                                      <strong>{row.model ?? "N/A"}</strong>
                                      <br />
                                      <small>{row.runtime ?? "N/A"}</small>
                                    </span>
                                  </div>
                                </td>
                                <td>{row.dataset ?? "N/A"}</td>
                                <td className="mono">
                                  {formatNumber(row.metrics.fps)}
                                </td>
                                <td className="mono">
                                  {formatNumber(
                                    row.metrics.inferenceMeanMs,
                                  )}{" "}
                                  ms
                                </td>
                                <td className="mono">
                                  {formatNumber(row.metrics.wallP95Ms)} ms
                                </td>
                                <td className="mono">
                                  {row.metrics.measuredFrames?.toLocaleString() ??
                                    "N/A"}
                                </td>
                                <td>
                                  {row.accuracy?.status === "not-computed"
                                    ? "미계산"
                                    : row.accuracy?.status ?? "N/A"}
                                </td>
                              </tr>
                            ))
                          ) : (
                            <tr>
                              <td colSpan={7}>
                                <EmptyState>
                                  완료된 모델 벤치마크가 없습니다.
                                </EmptyState>
                              </td>
                            </tr>
                          )}
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
                      <h2>오디오 모델 비교 준비 상태</h2>
                      <span>측정되지 않은 성능 수치는 N/A</span>
                    </div>
                    <span className="mono result-count">
                      {snapshot?.audio.sampleCount ?? 0} SAMPLES
                    </span>
                  </div>
                  <div className="audio-grid">
                    {audioCandidates.map((model) => {
                      const isMeasuredYamnet =
                        model.name === snapshot?.audio.model &&
                        (snapshot?.audio.sampleCount ?? 0) > 0;
                      return (
                        <article className="audio-model" key={model.name}>
                          <h3>{model.name}</h3>
                          <p>{model.note}</p>
                          <div className="audio-stat">
                            <span>macro F1</span>
                            <strong>N/A</strong>
                          </div>
                          <div className="audio-stat">
                            <span>mean latency</span>
                            <strong>
                              {isMeasuredYamnet
                                ? `${formatNumber(snapshot.audio.latencyMeanMs)} ms`
                                : "N/A"}
                            </strong>
                          </div>
                          <div className="audio-stat">
                            <span>measured samples</span>
                            <strong>
                              {isMeasuredYamnet
                                ? snapshot.audio.sampleCount
                                : "N/A"}
                            </strong>
                          </div>
                        </article>
                      );
                    })}
                  </div>
                </section>
              )}

              {activeTab === "timeline" && (
                <section className="panel">
                  <div className="panel-header">
                    <div className="panel-title">
                      <h2>실제 이벤트 메타데이터</h2>
                      <span>현재 event-dir의 trigger JSON만 표시</span>
                    </div>
                    <span className="mono result-count">
                      {events.length} EVENTS
                    </span>
                  </div>
                  <EventList events={events} />
                </section>
              )}
            </div>

            <aside className="stack">
              <section className="panel">
                <div className="panel-header">
                  <div className="panel-title">
                    <h2>최근 벤치마크 작업</h2>
                    <span>{benchmarkProgress?.status ?? "대기 중"}</span>
                  </div>
                  <span className="experiment-format">
                    {benchmarkProgress?.runtime ?? "NO RUN"}
                  </span>
                </div>
                {benchmarkProgress ? (
                  <div className="experiment-card">
                    <div className="experiment-top">
                      <div>
                        <p className="eyebrow">Vision benchmark</p>
                        <p className="experiment-model">
                          {benchmarkProgress.model ?? "N/A"}
                        </p>
                      </div>
                      <span className="score">
                        {benchmarkProgress.status ?? "UNKNOWN"}
                      </span>
                    </div>
                    <div className="progress-track">
                      <div
                        className="progress-fill"
                        style={{
                          width: `${Math.max(0, Math.min(100, progressPercent ?? 0))}%`,
                        }}
                      />
                    </div>
                    <div className="progress-meta mono">
                      <span>
                        {benchmarkProgress.progress.completedFrames?.toLocaleString() ??
                          "N/A"}{" "}
                        /{" "}
                        {benchmarkProgress.progress.totalFrames?.toLocaleString() ??
                          "N/A"}{" "}
                        frames
                      </span>
                      <span>
                        {progressPercent != null
                          ? `${progressPercent.toFixed(1)}%`
                          : "N/A"}
                      </span>
                    </div>
                    <div className="experiment-config">
                      <ConfigItem
                        label="Dataset"
                        value={benchmarkProgress.dataset ?? "N/A"}
                      />
                      <ConfigItem
                        label="Tasks"
                        value={`${benchmarkProgress.progress.completedTasks ?? "N/A"} / ${benchmarkProgress.progress.totalTasks ?? "N/A"}`}
                      />
                      <ConfigItem
                        label="Sample"
                        value={benchmarkProgress.current?.sampleId ?? "N/A"}
                      />
                      <ConfigItem
                        label="Updated"
                        value={formatTimestamp(benchmarkProgress.updatedAt)}
                      />
                    </div>
                  </div>
                ) : (
                  <EmptyState>
                    progress.json이 생성되면 진행률을 표시합니다.
                  </EmptyState>
                )}
              </section>

              <section className="panel">
                <div className="panel-header">
                  <div className="panel-title">
                    <h2>데이터 소스 상태</h2>
                    <span>파일 존재 여부와 freshness 기준</span>
                  </div>
                </div>
                <div className="stage-list">
                  {pipelineRows.map((stage) => (
                    <div className="stage-row" key={stage.index}>
                      <span
                        className={`stage-index ${stage.healthy ? "ok" : ""}`}
                      >
                        {stage.index}
                      </span>
                      <span className="stage-copy">
                        <strong>{stage.title}</strong>
                        <span>{stage.detail}</span>
                      </span>
                      <span className="stage-value">{stage.value}</span>
                    </div>
                  ))}
                </div>
              </section>

              <section className="panel">
                <div className="panel-header">
                  <div className="panel-title">
                    <h2>최근 실제 이벤트</h2>
                    <span>LOCAL METADATA</span>
                  </div>
                </div>
                <EventList events={events.slice(0, 6)} />
              </section>
            </aside>
          </div>

          <footer className="footer-note">
            <span>
              실측값이 없는 지표는 N/A로 표시하며 대체값을 만들지 않습니다.
            </span>
            <span className="mono">
              SCHEMA v0.1 · REFRESH 2.0s · LOCAL 8765 → JETSON 18765
            </span>
          </footer>
        </main>
      </div>
    </div>
  );
}

function Metric({
  label,
  value,
  unit,
  detail,
  accent = false,
}: {
  label: string;
  value: string;
  unit: string;
  detail: string;
  accent?: boolean;
}) {
  const className = ["metric-card", accent ? "accent" : ""]
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

function EmptyState({ children }: { children: ReactNode }) {
  return <div className="empty-state">{children}</div>;
}

function ConfigItem({ label, value }: { label: string; value: string }) {
  return (
    <div className="config-item">
      <span>{label}</span>
      <strong>{value}</strong>
    </div>
  );
}

function EventList({ events }: { events: Snapshot["events"] }) {
  if (!events.length) {
    return <EmptyState>현재 보존된 이벤트 메타데이터가 없습니다.</EmptyState>;
  }

  return (
    <div className="event-list">
      {events.map((event) => (
        <div className="event-row" key={event.eventId}>
          <span className="stage-index">•</span>
          <span className="event-copy">
            <strong>{event.eventType ?? "UNKNOWN EVENT"}</strong>
            <span>
              {event.className ?? "class N/A"} · confidence{" "}
              {formatNumber(event.confidence, 3)}
            </span>
            <span className="event-tag">
              {event.eventId.slice(0, 8)}
            </span>
          </span>
          <span className="event-time">
            {formatTimestamp(event.observedAt)}
          </span>
        </div>
      ))}
    </div>
  );
}
