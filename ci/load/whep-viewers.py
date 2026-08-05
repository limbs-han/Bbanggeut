#!/usr/bin/env python3
"""B축 — 같은 기기를 동시에 몇 명이 볼 수 있는가.

구조 확인 결과(StreamService.create):
  - 같은 기기의 시청자들은 **송출 1개를 공유**한다(findReusableStream).
    시청자마다 새로 만들어지는 것은 세션 row와 라이브 토큰뿐이다.
  - 세션 생성은 mapper.lockDevice(deviceId)로 **기기 단위 직렬화**된다.
    N명이 동시에 라이브를 켜면 그 row lock에서 줄을 선다 — 그 지연도 잰다.
  - 라이브 토큰 TTL 30초. whepUrl을 받으면 곧바로 연결해야 한다.
  - 뷰어 TTL 45초, 하트비트 15초. 하트비트를 멈추면 세션이 만료된다.

무엇이 진짜 한계인지에 대한 주의:
  이 스크립트는 aiortc로 실제 WebRTC 피어를 만든다 — MediaMTX에 가해지는
  부하는 진짜다. 그러나 **수신 프레임 수를 aiortc로 세면 파이썬 디코딩이
  먼저 병목**이 되어 서버가 아니라 부하 발생기를 측정하게 된다.
  그래서 판정 기준은 MediaMTX 자신의 카운터(readers·bytesSent)와 서버
  CPU다. --mediamtx-api 로 그 값을 함께 찍는다(9997은 loopback 전용이므로
  `ssh -L 9997:127.0.0.1:9997 ubuntu@<host>` 터널이 필요하다).
  실행 중 부하 발생기의 CPU가 포화되면 그 회차는 무효다.

필요한 것:
  pip install aiortc aiohttp

실행:
  python whep-viewers.py --device <deviceId> --viewers 10 --duration 60 \
      --base-url https://i15e201.p.ssafy.io --token "$ACCESS_TOKEN"

계단식으로 올린다: 10 → 20 → 40 → 80. 드롭이 처음 생기는 지점이 답이다.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import time
from dataclasses import dataclass, field
from urllib.parse import urljoin

import aiohttp
from aiortc import RTCPeerConnection, RTCSessionDescription


@dataclass
class ViewerResult:
    index: int
    session_ms: float | None = None      # 세션 생성 지연(row lock 경합 포함)
    ready_ms: float | None = None        # PENDING → READY 까지
    first_frame_ms: float | None = None  # WHEP 연결 후 첫 프레임까지
    frames: int = 0
    bytes_received: int = 0
    packets_received: int = 0
    packets_lost: int = 0
    error: str | None = None
    stages: list[str] = field(default_factory=list)


class Viewer:
    def __init__(self, index: int, args, session: aiohttp.ClientSession) -> None:
        self.index = index
        self.args = args
        self.http = session
        self.result = ViewerResult(index=index)
        self.pc: RTCPeerConnection | None = None
        self.session_id: str | None = None
        self.whep_location: str | None = None
        self._stop = asyncio.Event()

    def _auth(self) -> dict[str, str]:
        return {"Authorization": f"Bearer {self.args.token}"}

    async def open_session(self) -> str:
        """API-35 → 폴링(API-36) → whepUrl."""
        started = time.monotonic()
        url = f"{self.args.base_url}/api/devices/{self.args.device}/stream-sessions"
        async with self.http.post(url, headers=self._auth()) as response:
            body = await response.text()
            if response.status not in (200, 202):
                raise RuntimeError(f"세션 생성 실패 {response.status}: {body[:200]}")
            payload = json.loads(body)
        self.result.session_ms = (time.monotonic() - started) * 1000
        self.session_id = payload["sessionId"]

        whep_url = payload.get("whepUrl")
        # 앱과 같은 리듬으로 2초 간격 폴링한다. 기기가 START_STREAM을 받고
        # 송출을 올릴 때까지 PENDING이다(준비 지연 기본 3초).
        deadline = time.monotonic() + self.args.ready_timeout
        while not whep_url:
            if time.monotonic() > deadline:
                raise RuntimeError(f"READY 대기 시간 초과 (status={payload.get('status')})")
            await asyncio.sleep(2)
            get_url = f"{self.args.base_url}/api/stream-sessions/{self.session_id}"
            async with self.http.get(get_url, headers=self._auth()) as response:
                payload = json.loads(await response.text())
            status = payload.get("status")
            if status in ("FAILED", "CLOSED", "EXPIRED"):
                raise RuntimeError(f"세션 {status} (failureCode={payload.get('failureCode')})")
            whep_url = payload.get("whepUrl")
        self.result.ready_ms = (time.monotonic() - started) * 1000
        return whep_url

    async def connect_whep(self, whep_url: str) -> None:
        """recv-only SDP offer를 POST하고 answer를 적용한다.

        라이브 토큰 TTL이 30초다 — whepUrl을 받은 즉시 여기까지 와야 한다.
        """
        self.pc = RTCPeerConnection()
        self.pc.addTransceiver("video", direction="recvonly")
        self.pc.addTransceiver("audio", direction="recvonly")

        connected = asyncio.Event()
        started = time.monotonic()

        @self.pc.on("track")
        def on_track(track):  # noqa: ANN001 — aiortc 콜백
            asyncio.ensure_future(self._drain(track, connected, started))

        await self.pc.setLocalDescription(await self.pc.createOffer())
        # aiortc는 setLocalDescription에서 ICE 수집을 끝내므로 별도 대기가 없다.
        async with self.http.post(
            whep_url,
            data=self.pc.localDescription.sdp,
            headers={"Content-Type": "application/sdp"},
        ) as response:
            answer = await response.text()
            if response.status not in (200, 201):
                raise RuntimeError(f"WHEP 실패 {response.status}: {answer[:200]}")
            # 종료 시 이 URL로 DELETE해야 MediaMTX가 리더를 즉시 정리한다.
            # (DELETE가 nginx 인가에서 막혀도 무해하다 — 피어를 닫으면
            #  MediaMTX가 리더를 스스로 정리한다. 다만 정리가 늦어질 수 있어
            #  계단식 측정에서는 회차 사이에 여유를 둔다.)
            location = response.headers.get("Location")
            if location:
                self.whep_location = urljoin(str(response.url), location)

        await self.pc.setRemoteDescription(RTCSessionDescription(sdp=answer, type="answer"))
        try:
            await asyncio.wait_for(connected.wait(), timeout=self.args.frame_timeout)
        except asyncio.TimeoutError as failure:
            raise RuntimeError("첫 프레임 수신 시간 초과") from failure

    async def _drain(self, track, connected: asyncio.Event, started: float) -> None:
        """트랙을 계속 비운다.

        프레임 수는 참고값이다 — 파이썬 디코딩이 서버보다 먼저 막힐 수 있어서
        시청자 수가 커지면 이 숫자는 부하 발생기의 한계를 반영한다. 판정은
        MediaMTX 카운터로 한다.
        """
        while not self._stop.is_set():
            try:
                await track.recv()
            except Exception:  # noqa: BLE001 — 연결 종료도 여기로 온다
                return
            if track.kind == "video":
                self.result.frames += 1
                if self.result.first_frame_ms is None:
                    self.result.first_frame_ms = (time.monotonic() - started) * 1000
                    connected.set()

    async def heartbeat_loop(self) -> None:
        """15초 주기. 멈추면 뷰어 TTL 45초에 세션이 만료된다."""
        url = f"{self.args.base_url}/api/stream-sessions/{self.session_id}/heartbeat"
        while not self._stop.is_set():
            try:
                await asyncio.sleep(15)
                if self._stop.is_set():
                    return
                async with self.http.post(url, headers=self._auth()) as response:
                    if response.status not in (204, 200):
                        self.result.stages.append(f"heartbeat {response.status}")
            except asyncio.CancelledError:
                return
            except Exception as failure:  # noqa: BLE001
                self.result.stages.append(f"heartbeat error {failure}")

    async def collect_stats(self) -> None:
        """inbound-rtp 통계. 디코딩과 무관하게 손실을 보여 준다."""
        if self.pc is None:
            return
        try:
            report = await self.pc.getStats()
        except Exception:  # noqa: BLE001
            return
        for entry in report.values():
            if getattr(entry, "type", None) == "inbound-rtp":
                self.result.bytes_received += getattr(entry, "bytesReceived", 0) or 0
                self.result.packets_received += getattr(entry, "packetsReceived", 0) or 0
                self.result.packets_lost += getattr(entry, "packetsLost", 0) or 0

    async def close(self) -> None:
        self._stop.set()
        if self.whep_location:
            try:
                async with self.http.delete(self.whep_location):
                    pass
            except Exception:  # noqa: BLE001
                pass
        if self.pc is not None:
            await self.pc.close()
        if self.session_id:
            try:
                url = f"{self.args.base_url}/api/stream-sessions/{self.session_id}"
                async with self.http.delete(url, headers=self._auth()):
                    pass
            except Exception:  # noqa: BLE001
                pass

    async def run(self) -> ViewerResult:
        try:
            whep_url = await self.open_session()
            await self.connect_whep(whep_url)
            heartbeat = asyncio.ensure_future(self.heartbeat_loop())
            await asyncio.sleep(self.args.duration)
            await self.collect_stats()
            heartbeat.cancel()
        except Exception as failure:  # noqa: BLE001 — 결과로 보고한다
            self.result.error = f"{type(failure).__name__}: {failure}"
        finally:
            await self.close()
        return self.result


async def mediamtx_snapshot(api_base: str, label: str) -> None:
    """MediaMTX가 보는 리더 수·전송량. 이게 판정 기준이다."""
    if not api_base:
        return
    try:
        async with aiohttp.ClientSession() as http:
            async with http.get(f"{api_base}/v3/paths/list", timeout=aiohttp.ClientTimeout(total=5)) as response:
                payload = await response.json()
    except Exception as failure:  # noqa: BLE001
        print(f"[MediaMTX {label}] 조회 실패: {failure}")
        return
    for item in payload.get("items", []):
        print(
            f"[MediaMTX {label}] path={item.get('name')} "
            f"ready={item.get('ready')} readers={len(item.get('readers') or [])} "
            f"bytesSent={item.get('bytesSent')}"
        )


async def main() -> None:
    parser = argparse.ArgumentParser(description="WHEP 동시 시청 부하")
    parser.add_argument("--base-url", default=os.environ.get("BASE_URL", "https://i15e201.p.ssafy.io"))
    parser.add_argument("--token", default=os.environ.get("ACCESS_TOKEN", ""), help="앱 액세스 토큰")
    parser.add_argument("--device", default=os.environ.get("DEVICE_ID", ""), help="기기 UUID")
    parser.add_argument("--viewers", type=int, default=10)
    parser.add_argument("--duration", type=float, default=60, help="시청 유지 시간(초)")
    parser.add_argument("--ready-timeout", type=float, default=45)
    parser.add_argument("--frame-timeout", type=float, default=20)
    parser.add_argument("--stagger", type=float, default=0.0,
                        help="시청자 사이 간격(초). 0이면 완전 동시 — lockDevice 경합을 본다")
    parser.add_argument("--mediamtx-api", default=os.environ.get("MEDIAMTX_API", ""),
                        help="예: http://127.0.0.1:9997 (SSH 터널 필요)")
    args = parser.parse_args()

    if not args.token or not args.device:
        parser.error("--token 과 --device 는 필수다")

    print(f"시청자 {args.viewers}명, {args.duration:.0f}초 유지, 기기 {args.device}")
    await mediamtx_snapshot(args.mediamtx_api, "before")

    timeout = aiohttp.ClientTimeout(total=None, sock_connect=15, sock_read=60)
    async with aiohttp.ClientSession(timeout=timeout) as http:
        viewers = [Viewer(index, args, http) for index in range(args.viewers)]

        async def launch(viewer: Viewer) -> ViewerResult:
            if args.stagger:
                await asyncio.sleep(viewer.index * args.stagger)
            return await viewer.run()

        # 시청 중간에 한 번 MediaMTX를 찍는다 — 그때가 최대 동시 리더 시점이다.
        async def peek() -> None:
            await asyncio.sleep(min(args.duration * 0.6, args.duration))
            await mediamtx_snapshot(args.mediamtx_api, "during")

        results, _ = await asyncio.gather(
            asyncio.gather(*(launch(viewer) for viewer in viewers)),
            peek(),
        )

    await mediamtx_snapshot(args.mediamtx_api, "after")

    print()
    print("idx  session_ms  ready_ms  first_frame_ms  frames  pkts  lost  error")
    for result in results:
        print(
            f"{result.index:3d}  "
            f"{(f'{result.session_ms:.0f}' if result.session_ms else '-'):>10}  "
            f"{(f'{result.ready_ms:.0f}' if result.ready_ms else '-'):>8}  "
            f"{(f'{result.first_frame_ms:.0f}' if result.first_frame_ms else '-'):>14}  "
            f"{result.frames:>6}  {result.packets_received:>4}  "
            f"{result.packets_lost:>4}  {result.error or ''}"
        )

    connected = [r for r in results if r.error is None]
    failed = [r for r in results if r.error is not None]
    print()
    print(f"연결 성공 {len(connected)}/{len(results)}")
    if connected:
        session_times = sorted(r.session_ms for r in connected if r.session_ms)
        if session_times:
            print(f"세션 생성 지연 최대 {session_times[-1]:.0f} ms "
                  f"(중앙 {session_times[len(session_times) // 2]:.0f} ms) "
                  "— lockDevice 직렬화 구간")
        total_lost = sum(r.packets_lost for r in connected)
        total_received = sum(r.packets_received for r in connected)
        if total_received:
            print(f"패킷 손실률 {100 * total_lost / (total_received + total_lost):.2f}%")
    if failed:
        print(f"실패 {len(failed)}건 — 사유별로 세어 볼 것 (DEVICE_OFFLINE·토큰 만료는 서버 한계가 아니다)")
    print()
    print("판정: 위 프레임 수가 아니라 MediaMTX readers·bytesSent와 서버 CPU를 본다.")
    print("      부하 발생기 CPU가 포화됐으면 그 회차는 무효다.")


if __name__ == "__main__":
    asyncio.run(main())
