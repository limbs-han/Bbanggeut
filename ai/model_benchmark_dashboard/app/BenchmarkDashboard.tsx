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
  systemSource?: "benchmark" | "operational";
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
    comparison?: {
      id?: string | null;
      trialIndex?: number | null;
      trialCount?: number | null;
      executionOrder?: number | null;
    } | null;
    model: string | null;
    runtime: string | null;
    modelDetails?: {
      sizeBytes?: number | null;
      sha256?: string | null;
    };
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
      eventType?: "laughter" | "clap" | string;
      standard?: {
        confidenceFloor?: number | null;
        precision?: number | null;
        recall?: number | null;
        mAP50?: number | null;
        mAP50_95?: number | null;
      };
      operatingPoint?: {
        threshold?: number | null;
        confidence?: number | null;
        matchIou?: number | null;
        truePositive?: number | null;
        falsePositive?: number | null;
        falseNegative?: number | null;
        trueNegative?: number | null;
        precision?: number | null;
        recall?: number | null;
        f1?: number | null;
        falsePositivesPerHour?: number | null;
        falseEventCount?: number | null;
      };
      byCohort?: Record<
        "localDirect" | "continuousNegative" | "externalGeneralization" | string,
        {
          sampleCount?: number | null;
          precision?: number | null;
          recall?: number | null;
          f1?: number | null;
          falseEventsPerHour?: number | null;
          falseEventCount?: number | null;
          negativeDurationSeconds?: number | null;
        }
      >;
      byScenario?: Array<{
        scenario: string;
        imageCount: number;
        truePositive: number;
        falsePositive: number;
        falseNegative: number;
        precision: number;
        recall: number;
        f1: number;
      }>;
      failureCases?: Array<{
        image: string;
        scenario: string;
        falsePositive: number;
        falseNegative: number;
      }>;
    } | null;
    configuration?: {
      imgsz?: number | null;
      batch?: number | null;
      mapConfidence?: number | null;
      operatingConfidence?: number | null;
      nmsIou?: number | null;
      matchIou?: number | null;
    } | null;
    resources?: {
      status?: string;
      sampleCount?: number | null;
      gpuPercentMax?: number | null;
      ramUsedMbMax?: number | null;
      temperatureCMax?: number | null;
      powerMwMax?: number | null;
    } | null;
    datasetDetails?: {
      imageCount?: number | null;
      emptyImageCount?: number | null;
      boxCount?: number | null;
      duplicateImageCount?: number | null;
      sha256?: string | null;
    } | null;
    selectionPolicy?: {
      status?: string;
      minimumFps?: number | null;
      maximumWallP95Ms?: number | null;
      minimumRecall?: number | null;
      maximumMap50_95Gap?: number | null;
      maximumFalsePositivesPerHour?: number | null;
      priority?: string | null;
      rule?: string;
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
      completedSamples?: number | null;
      totalSamples?: number | null;
      completedTasks?: number | null;
      totalTasks?: number | null;
      percent?: number | null;
      stage?: string | null;
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
    note: "TFLite CPU 기준선 모델입니다. 웃음·박수별 Recall과 시간당 오탐을 함께 확인합니다.",
  },
  {
    name: "EfficientAT MN10",
    note: "Jetson CUDA에서 실행하는 경량 AudioSet 모델입니다.",
  },
  {
    name: "PANNs CNN10",
    note: "AudioSet CNN10 기준 모델입니다. 정확도와 자원 사용량을 함께 비교합니다.",
  },
];

function formatNumber(
  value: number | null | undefined,
  digits = 1,
): string {
  return value == null || !Number.isFinite(value) ? "N/A" : value.toFixed(digits);
}

function formatPercent(
  value: number | null | undefined,
  digits = 1,
): string {
  return value == null ? "N/A" : `${(value * 100).toFixed(digits)}%`;
}

function average(values: Array<number | null | undefined>): number | null {
  const measured = values.filter(
    (value): value is number => value != null && Number.isFinite(value),
  );
  return measured.length
    ? measured.reduce((sum, value) => sum + value, 0) / measured.length
    : null;
}

const defaultSelectionPolicy = {
  minimumFps: 20,
  maximumWallP95Ms: 50,
  minimumRecall: 0.9,
  maximumMap50_95Gap: 0.02,
};

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
  const comparisons = useMemo(
    () =>
      snapshot?.comparisons.filter((row) => row.component === "vision") ?? [],
    [snapshot?.comparisons],
  );
  const audioComparisons = useMemo(
    () =>
      snapshot?.comparisons.filter((row) => row.component === "audio") ?? [],
    [snapshot?.comparisons],
  );
  const comparisonDecisions = useMemo(() => {
    const computed = comparisons.filter(
      (row) =>
        row.accuracy?.status === "computed" &&
        row.accuracy.standard?.mAP50_95 != null &&
        row.accuracy.operatingPoint?.recall != null,
    );
    const mapValues = computed
      .map((row) => row.accuracy?.standard?.mAP50_95)
      .filter((value): value is number => value != null);
    const bestMap = mapValues.length ? Math.max(...mapValues) : null;

    return computed.map((row) => {
      const policy = {
        minimumFps:
          row.selectionPolicy?.minimumFps ??
          defaultSelectionPolicy.minimumFps,
        maximumWallP95Ms:
          row.selectionPolicy?.maximumWallP95Ms ??
          defaultSelectionPolicy.maximumWallP95Ms,
        minimumRecall:
          row.selectionPolicy?.minimumRecall ??
          defaultSelectionPolicy.minimumRecall,
        maximumMap50_95Gap:
          row.selectionPolicy?.maximumMap50_95Gap ??
          defaultSelectionPolicy.maximumMap50_95Gap,
      };
      const fps = row.metrics.fps;
      const wallP95 = row.metrics.wallP95Ms;
      const recall = row.accuracy?.operatingPoint?.recall;
      const map = row.accuracy?.standard?.mAP50_95;
      const mapGap = bestMap != null && map != null ? bestMap - map : null;
      const failures: string[] = [];
      if (fps == null || fps < policy.minimumFps) failures.push("FPS");
      if (wallP95 == null || wallP95 > policy.maximumWallP95Ms)
        failures.push("P95 지연");
      if (recall == null || recall < policy.minimumRecall)
        failures.push("Recall");
      if (mapGap == null || mapGap > policy.maximumMap50_95Gap)
        failures.push("mAP 격차");
      return {
        row,
        policy,
        mapGap,
        passes: failures.length === 0,
        failures,
      };
    });
  }, [comparisons]);
  const recommendedDecision = [...comparisonDecisions]
    .filter((decision) => decision.passes)
    .sort(
      (first, second) =>
        (second.row.metrics.fps ?? -1) - (first.row.metrics.fps ?? -1),
    )[0];
  const focusDecision =
    recommendedDecision ??
    [...comparisonDecisions].sort(
      (first, second) =>
        (second.row.accuracy?.standard?.mAP50_95 ?? -1) -
        (first.row.accuracy?.standard?.mAP50_95 ?? -1),
    )[0];
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
      count: String(audioComparisons.length),
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
                  ? `${snapshot.systemSource === "benchmark" ? "정확도 평가" : "운영"} · 보드 전력 ${(snapshot.system.powerMw / 1000).toFixed(2)} W`
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

                  <section className="panel evidence-panel">
                    <div className="panel-header">
                      <div className="panel-title">
                        <h2>발표 질문을 커버하는 모델 선정 근거</h2>
                        <span>
                          정확도와 실시간성을 동일한 Jetson 조건에서 함께 판단
                        </span>
                      </div>
                      <span className="mono result-count">
                        {comparisonDecisions.length} ACCURACY RUNS
                      </span>
                    </div>
                    <div className="evidence-grid">
                      <article className="evidence-card">
                        <span className="evidence-kicker">QUESTION 01</span>
                        <h3>왜 이 YOLO 모델인가?</h3>
                        <strong>
                          {recommendedDecision?.row.model ??
                            (comparisonDecisions.length
                              ? "기준 통과 모델 없음"
                              : "정확도 평가 대기")}
                        </strong>
                        <p>
                          합격 모델 중 mAP 손실을 제한하고 FPS가 가장 높은
                          모델을 선택합니다. 최신 모델명이나 COCO 수치만으로
                          결정하지 않습니다.
                        </p>
                      </article>
                      <article className="evidence-card">
                        <span className="evidence-kicker">QUESTION 02</span>
                        <h3>실제 환경에서도 유효한가?</h3>
                        <strong>
                          {focusDecision?.row.datasetDetails?.imageCount ?? "N/A"}
                          장 · {focusDecision?.row.datasetDetails?.boxCount ?? "N/A"}
                          박스
                        </strong>
                        <p>
                          Jetson 피크: GPU {focusDecision?.row.resources?.gpuPercentMax != null ? `${formatNumber(focusDecision.row.resources.gpuPercentMax, 0)}%` : "N/A"},
                          {" "}RAM {focusDecision?.row.resources?.ramUsedMbMax != null ? `${formatNumber(focusDecision.row.resources.ramUsedMbMax, 0)} MB` : "N/A"},
                          {" "}온도 {focusDecision?.row.resources?.temperatureCMax != null ? `${formatNumber(focusDecision.row.resources.temperatureCMax)}°C` : "N/A"},
                          {" "}전력 {focusDecision?.row.resources?.powerMwMax != null ? `${formatNumber(focusDecision.row.resources.powerMwMax / 1000, 2)} W` : "N/A"}.
                          같은 사무실 프레임과 사람 클래스만 평가합니다.
                        </p>
                      </article>
                      <article className="evidence-card">
                        <span className="evidence-kicker">SERVICE GATE</span>
                        <h3>선정 기준</h3>
                        <strong>20 FPS · 50 ms · Recall 90%</strong>
                        <p>
                          최고 mAP50-95와의 차이가 2%p 이내인 모델만 후보로
                          유지합니다. 기준값은 첫 실측 후 서비스 요구에 맞게
                          확정합니다.
                        </p>
                      </article>
                    </div>
                    {focusDecision && (
                      <div className="evidence-footnote mono">
                        DATASET SHA {focusDecision.row.datasetDetails?.sha256?.slice(0, 12) ?? "N/A"}
                        {" · "}MODEL SHA {focusDecision.row.modelDetails?.sha256?.slice(0, 12) ?? "N/A"}
                        {" · "}CONF {focusDecision.row.configuration?.operatingConfidence ?? "N/A"}
                        {" · "}MATCH IOU {focusDecision.row.configuration?.matchIou ?? "N/A"}
                        {" · "}DUPLICATES {focusDecision.row.datasetDetails?.duplicateImageCount ?? "N/A"}
                      </div>
                    )}
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
                            <th>P@0.25 ↑</th>
                            <th>R@0.25 ↑</th>
                            <th>F1@0.25 ↑</th>
                            <th>mAP50 ↑</th>
                            <th>mAP50-95 ↑</th>
                            <th>GPU max</th>
                            <th>판정</th>
                          </tr>
                        </thead>
                        <tbody>
                          {comparisons.length ? (
                            comparisons.map((row, index) => {
                              const decision = comparisonDecisions.find(
                                (candidate) => candidate.row.runId === row.runId,
                              );
                              const selected =
                                recommendedDecision?.row.runId === row.runId;
                              return (
                              <tr
                                key={row.runId ?? `${row.model}-${index}`}
                                className={selected ? "selected" : undefined}
                              >
                                <td>
                                  <div className="model-cell">
                                    <i className="model-dot" />
                                    <span>
                                      <strong>{row.model ?? "N/A"}</strong>
                                      <br />
                                      <small>{row.runtime ?? "N/A"}</small>
                                      {row.comparison?.trialIndex != null && (
                                        <small>
                                          R{row.comparison.trialIndex}/
                                          {row.comparison.trialCount ?? "?"} · ORDER{" "}
                                          {row.comparison.executionOrder ?? "?"}
                                        </small>
                                      )}
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
                                  {formatPercent(
                                    row.accuracy?.operatingPoint?.precision,
                                  )}
                                </td>
                                <td className="mono">
                                  {formatPercent(
                                    row.accuracy?.operatingPoint?.recall,
                                  )}
                                </td>
                                <td className="mono">
                                  {formatPercent(row.accuracy?.operatingPoint?.f1)}
                                </td>
                                <td className="mono">
                                  {formatPercent(row.accuracy?.standard?.mAP50)}
                                </td>
                                <td className="mono">
                                  {formatPercent(row.accuracy?.standard?.mAP50_95)}
                                </td>
                                <td className="mono">
                                  {row.resources?.gpuPercentMax != null
                                    ? `${formatNumber(row.resources.gpuPercentMax, 0)}%`
                                    : "N/A"}
                                </td>
                                <td>
                                  {selected
                                    ? "추천"
                                    : decision?.passes
                                      ? "통과"
                                      : decision
                                        ? `탈락: ${decision.failures.join(", ")}`
                                        : row.accuracy?.status === "not-computed"
                                          ? "정확도 미계산"
                                          : "평가 대기"}
                                </td>
                              </tr>
                              );
                            })
                          ) : (
                            <tr>
                              <td colSpan={13}>
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

                  {focusDecision?.row.accuracy?.byScenario?.length ? (
                    <section className="panel">
                      <div className="panel-header">
                        <div className="panel-title">
                          <h2>조건별 정확도와 실패 사례</h2>
                          <span>
                            {focusDecision.row.model} · 운영 confidence {focusDecision.row.configuration?.operatingConfidence ?? "N/A"}
                          </span>
                        </div>
                        <span className="mono result-count">
                          {focusDecision.row.accuracy.byScenario.length} SCENARIOS
                        </span>
                      </div>
                      <div className="scenario-layout">
                        <div className="comparison-wrap">
                          <table className="comparison-table compact-table">
                            <thead>
                              <tr>
                                <th>장면</th>
                                <th>Images</th>
                                <th>Precision</th>
                                <th>Recall</th>
                                <th>F1</th>
                                <th>FP</th>
                                <th>FN</th>
                              </tr>
                            </thead>
                            <tbody>
                              {focusDecision.row.accuracy.byScenario.map((row) => (
                                <tr key={row.scenario}>
                                  <td>{row.scenario}</td>
                                  <td className="mono">{row.imageCount}</td>
                                  <td className="mono">{formatPercent(row.precision)}</td>
                                  <td className="mono">{formatPercent(row.recall)}</td>
                                  <td className="mono">{formatPercent(row.f1)}</td>
                                  <td className="mono">{row.falsePositive}</td>
                                  <td className="mono">{row.falseNegative}</td>
                                </tr>
                              ))}
                            </tbody>
                          </table>
                        </div>
                        <div className="failure-list">
                          <h3>오류가 많은 프레임</h3>
                          {(focusDecision.row.accuracy.failureCases ?? []).slice(0, 6).map((row) => (
                            <div className="failure-row" key={row.image}>
                              <span>{row.image}</span>
                              <strong className="mono">FP {row.falsePositive} · FN {row.falseNegative}</strong>
                            </div>
                          ))}
                          {!(focusDecision.row.accuracy.failureCases ?? []).length && (
                            <p>운영 임계값에서 기록된 FP/FN이 없습니다.</p>
                          )}
                        </div>
                      </div>
                    </section>
                  ) : null}
                </>
              )}

              {activeTab === "audio" && (
                <section className="panel">
                  <div className="panel-header">
                    <div className="panel-title">
                      <h2>오디오 이벤트 모델 비교</h2>
                      <span>웃음과 연속 박수를 동일 데이터·임계값 정책으로 비교</span>
                    </div>
                    <span className="mono result-count">
                      {audioComparisons.length} RUNS
                    </span>
                  </div>
                  <div className="audio-grid">
                    {audioCandidates.map((model) => {
                      const measured = audioComparisons.filter(
                        (row) => row.model === model.name,
                      );
                      const laughter = measured.filter(
                        (row) => row.accuracy?.eventType === "laughter",
                      );
                      const clap = measured.filter(
                        (row) => row.accuracy?.eventType === "clap",
                      );
                      const laughterF1 = average(
                        laughter.map(
                          (row) =>
                            row.accuracy?.byCohort?.localDirect?.f1,
                        ),
                      );
                      const laughterRecall = average(
                        laughter.map(
                          (row) =>
                            row.accuracy?.byCohort?.localDirect?.recall,
                        ),
                      );
                      const laughterFalseRate = average(
                        laughter.map(
                          (row) =>
                            row.accuracy?.byCohort?.continuousNegative
                              ?.falseEventsPerHour,
                        ),
                      );
                      const laughterExternalF1 = average(
                        laughter.map(
                          (row) =>
                            row.accuracy?.byCohort?.externalGeneralization?.f1,
                        ),
                      );
                      const laughterExternalRecall = average(
                        laughter.map(
                          (row) =>
                            row.accuracy?.byCohort?.externalGeneralization
                              ?.recall,
                        ),
                      );
                      const clapF1 = average(
                        clap.map(
                          (row) => row.accuracy?.byCohort?.localDirect?.f1,
                        ),
                      );
                      const clapRecall = average(
                        clap.map(
                          (row) =>
                            row.accuracy?.byCohort?.localDirect?.recall,
                        ),
                      );
                      const clapFalseRate = average(
                        clap.map(
                          (row) =>
                            row.accuracy?.byCohort?.continuousNegative
                              ?.falseEventsPerHour,
                        ),
                      );
                      const clapExternalF1 = average(
                        clap.map(
                          (row) =>
                            row.accuracy?.byCohort?.externalGeneralization?.f1,
                        ),
                      );
                      const clapExternalRecall = average(
                        clap.map(
                          (row) =>
                            row.accuracy?.byCohort?.externalGeneralization
                              ?.recall,
                        ),
                      );
                      const latency = average(
                        measured.map((row) => row.metrics.inferenceP95Ms),
                      );
                      return (
                        <article className="audio-model" key={model.name}>
                          <h3>{model.name}</h3>
                          <p>{model.note}</p>
                          <div className="audio-stat">
                            <span>직접 수집 웃음 F1 / Recall</span>
                            <strong>
                              {formatPercent(laughterF1)} /{" "}
                              {formatPercent(laughterRecall)}
                            </strong>
                          </div>
                          <div className="audio-stat">
                            <span>1시간 음성 웃음 FP/hour</span>
                            <strong>
                              {formatNumber(
                                laughterFalseRate,
                                2,
                              )}
                            </strong>
                          </div>
                          <div className="audio-stat">
                            <span>직접 수집 박수 F1 / Recall</span>
                            <strong>
                              {formatPercent(clapF1)} /{" "}
                              {formatPercent(clapRecall)}
                            </strong>
                          </div>
                          <div className="audio-stat">
                            <span>1시간 음성 박수 FP/hour</span>
                            <strong>
                              {formatNumber(
                                clapFalseRate,
                                2,
                              )}
                            </strong>
                          </div>
                          <div className="audio-stat">
                            <span>ESC-50 웃음 F1 / Recall</span>
                            <strong>
                              {formatPercent(laughterExternalF1)} /{" "}
                              {formatPercent(laughterExternalRecall)}
                            </strong>
                          </div>
                          <div className="audio-stat">
                            <span>ESC-50 박수 F1 / Recall</span>
                            <strong>
                              {formatPercent(clapExternalF1)} /{" "}
                              {formatPercent(clapExternalRecall)}
                            </strong>
                          </div>
                          <div className="audio-stat">
                            <span>추론 P95</span>
                            <strong>
                              {latency != null
                                ? `${formatNumber(latency, 2)} ms`
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
                        <p className="eyebrow">
                          {benchmarkProgress.component === "audio"
                            ? "Audio benchmark"
                            : "Vision benchmark"}
                        </p>
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
                        {(benchmarkProgress.component === "audio"
                          ? benchmarkProgress.progress.completedSamples
                          : benchmarkProgress.progress.completedFrames
                        )?.toLocaleString() ?? "N/A"}{" "}
                        /{" "}
                        {(benchmarkProgress.component === "audio"
                          ? benchmarkProgress.progress.totalSamples
                          : benchmarkProgress.progress.totalFrames
                        )?.toLocaleString() ?? "N/A"}{" "}
                        {benchmarkProgress.component === "audio"
                          ? "samples"
                          : "frames"}
                      </span>
                      <span>
                        {progressPercent != null
                          ? `${progressPercent.toFixed(1)}%`
                          : "N/A"}
                      </span>
                    </div>
                    <div className="experiment-config">
                      <ConfigItem
                        label="Stage"
                        value={benchmarkProgress.progress.stage ?? "N/A"}
                      />
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
