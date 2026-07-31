import type { Metadata } from "next";
import { BenchmarkDashboard } from "./BenchmarkDashboard";

export const metadata: Metadata = {
  title: "WJ Edge Observatory",
  description:
    "Jetson 비전·오디오 모델의 성능과 이벤트 파이프라인을 비교하는 로컬 대시보드",
};

export default function Home() {
  return <BenchmarkDashboard />;
}
