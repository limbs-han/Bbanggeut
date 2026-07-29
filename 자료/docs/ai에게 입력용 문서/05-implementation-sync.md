# 구현 동기화 델타 (2026-07-29, AI/코딩 에이전트용)

> 기준: `master` 5911e04를 병합한 `codex/chanhyeong-study`
> 01~04의 2026-07-27 스냅샷과 충돌하면 이 파일을 우선한다.

## 상태 델타

| 키 | 상태 | 사실 |
|---|---|---|
| LIVE-WHEP | 구현 | `StreamSessionResponse`에 `whepUrl` 추가. READY 세션은 `playUrl`(HLS)과 `whepUrl`을 함께 반환 |
| LIVE-CLIENT | 구현 | Flutter는 WHEP를 먼저 연결하고 실패하면 HLS로 폴백 |
| LIVE-PROXY | 구현 | Nginx `/webrtc/.../whep` → MediaMTX `127.0.0.1:8889`; 미디어 ICE UDP 8189 |
| FN-A38-UI | 부분 구현에서 구현으로 변경 | `LaughReportContentScreen` 존재. 로드된 `videos` 중 `triggerType == LAUGHTER`를 단말 집계 |
| FN-S26/API-51 | 제안·미구현 유지 | 서버 endpoint·DTO·service 없음. 구현됐다고 가정 금지 |
| DEPLOY-BUNDLE | 구현 | JAR + `backend-deploy.tar.gz`; 운영 배포는 수동 승인 |
| DEPLOY-JRE | 구현 | 배포 검증이 JDK `jar` 명령에 의존하지 않음 |
| MINIO-KES | 변경 | 미구성 KES 강제 제거. 비공개 버킷과 presigned URL 원칙 유지 |
| DEVICE-LCD-TEST | 구현 | `ai/device_agent/lcd_test.py`와 `tests/test_lcd.py` |
| FRONTEND-STT | 기준 브랜치 미포함 | `origin/develop/frontend`에는 FN-A39가 있으나 `master` 5911e04에는 없음 |
| DEVICE-LCD-REGISTRATION | 기준 브랜치 미포함 | `origin/develop/device` 후속 커밋에만 있음 |

## 라이브 응답 해석

`POST /api/devices/{deviceId}/stream-sessions` 및 세션 조회 응답의 기존 필드에 다음이 추가됐다.

```json
{
  "status": "READY",
  "playUrl": "https://.../hls/live/{streamId}/index.m3u8?token=...",
  "whepUrl": "https://.../webrtc/live/{streamId}/whep?token=..."
}
```

- `whepUrl != null`: WHEP 우선 연결
- WHEP/ICE 실패: `playUrl` HLS 폴백
- 둘 다 접근 토큰 검증 대상
- Spring은 세션·권한·토큰을 관리하는 제어 평면이고 MediaMTX가 미디어 바이트를 전달

## 에이전트 금지 가정

- `LaughReportContentScreen`의 존재를 API-51 구현 완료로 해석하지 말 것.
- `develop/*` 커밋을 `master` 운영 반영 완료로 표시하지 말 것.
- WebRTC 도입을 이유로 HLS 설정·응답 필드를 제거하지 말 것.
- MediaMTX 8889를 공인망에 직접 노출하지 말 것.
- 운영 배포 승인 작업을 사용자 요청 없이 승인하지 말 것.
