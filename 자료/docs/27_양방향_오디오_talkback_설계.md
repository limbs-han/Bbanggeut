# 양방향 오디오(talkback) 설계

> 문서 상태: `[심화]` 구현 진행 중
> 관련 계약: [`openapi.yaml`](../api/openapi.yaml), [`mqtt-contract.md`](../api/mqtt-contract.md)

## 1. 범위

앱 마이크 오디오를 기기 스피커로 보내는 역방향 경로를 추가한다. 영상은 기존대로 기기에서 앱으로만 흐른다. 홈캠에 필요한 것은 인터폰이며, 양방향 영상은 요구되지 않았다.

기존 라이브 경로는 그대로 둔다.

```
기기  --RTSPS publish--> MediaMTX(live/{streamId})     --WHEP--> 앱   (기존)
앱    --WHIP publish---> MediaMTX(talkback/{streamId}) --RTSP--> 기기 (신규)
```

시그널링 포트와 ICE 포트는 재생과 동일하다. `443/TCP`와 `8189/UDP` 외에 새로 여는 포트는 없다.

## 2. 왜 반이중(half-duplex)인가

기기에는 에코 제거(AEC)가 없다. 스피커에서 나온 소리가 기기 마이크로 다시 들어가면 다음 순환이 닫힌다.

```
기기 스피커 → 기기 마이크 → 라이브 업링크 → 앱 스피커 → 앱 마이크 → talkback → 기기 스피커
```

순환은 앱에서 끊는다. 발화하는 동안 앱은 자신의 WHEP 재생을 뮤트하고, 버튼을 뗄 때 복구한다.

기기에서 끊지 않는 이유는 명확하다. 기기가 업링크 오디오를 뮤트하려면 라이브 송출 ffmpeg를 `-an`으로 재시작해야 하고, 그러면 말할 때마다 영상이 끊긴다. 앱 쪽 뮤트는 재시작이 없고 즉시 적용된다.

다른 시청자에게는 기기 스피커 소리가 그대로 들린다. 같은 방에서 나는 소리이므로 의도된 동작이다.

기기당 동시 발화자는 한 명으로 제한한다. 두 사람이 동시에 말하면 서로의 뮤트가 상대의 순환을 끊어주지 못한다.

앱은 푸시투토크(버튼을 누르는 동안만 발화)로 이 제약을 사용자에게 자연스럽게 노출한다.

발화 중 라이브 소리가 꺼지는 것은 화면에 명시한다. 스피커 아이콘을 꺼짐 상태로 바꾸고 "말하는 중 · 라이브 소리 잠시 꺼짐" 표시를 띄운다. 표시하지 않으면 사용자는 이 뮤트를 무음 버그로 오해한다.

디스코드처럼 전이중(full-duplex)으로 열지 않는 이유는 지연이다. 디스코드는 모든 단말이 AEC를 돌리고 왕복 지연이 짧아 에코를 소프트웨어로 지울 수 있다. 이 시스템의 순환은 폰 → 서버 → 기기 스피커 → 기기 마이크 → 서버 → 폰으로 네트워크를 두 번 건너 1초 안팎이 걸리고, 이는 폰 AEC가 참조할 수 있는 범위 밖이다. 사용자가 헤드폰을 써도 기기 스피커와 기기 마이크는 같은 방에 있어 그쪽 커플링은 사라지지 않는다. 상용 홈캠(Ring, Nest 등)이 대부분 반이중 푸시투토크인 이유와 같다.

## 3. 발화 권한

`device_talkbacks` 테이블은 기기당 최대 한 행이다. `device_id`가 기본 키이므로 행의 존재 자체가 발화 권한이다.

권한 획득은 `INSERT ... ON CONFLICT (device_id) DO UPDATE ... WHERE` 한 번으로 끝난다. 다른 세션이 유효한 권한을 쥐고 있으면 `WHERE`가 갱신을 막아 아무 행도 반환되지 않고, 서버는 409 `TALKBACK_BUSY`로 거절한다.

같은 세션이 다시 호출하면 만료 시각만 갱신되어 연장으로 동작한다.

권한 수명은 30초이며 시청자 heartbeat(15초)가 함께 연장한다. 발화용 heartbeat를 따로 두지 않은 이유는 앱이 두 주기를 각각 관리해야 하고, 한쪽만 실패하면 권한이 남아 다른 구성원이 영영 말하지 못하기 때문이다.

연장은 두 곳에 반영돼야 한다. DB 행만 연장하면 기기 플레이어가 처음 받은 `hardExpiresAt`에 스스로 스피커를 닫아, 권한은 살아 있는데 소리만 30초에 끊긴다. 그래서 heartbeat가 권한을 연장할 때마다 서버는 멱등 `START_TALKBACK`을 재발행하고, 기기는 같은 `streamId`면 재생을 끊지 않고 만료 시각만 민다.

앱이 heartbeat 없이 사라지면 `StreamLifecycleWorker`가 5초마다 만료된 권한을 회수하고 기기에 `STOP_TALKBACK`을 보낸다.

## 4. 권한 범위

발화는 라이브를 볼 수 있는 사람과 같은 범위, 즉 대상 기기의 활성 `OWNER` 또는 `MEMBER`에게 허용한다. 이미 집 안을 보고 들을 수 있는 구성원에게만 열리는 경로이므로 별도 역할을 만들지 않았다.

`OWNER`로만 좁히려면 `StreamService.openTalkback`에서 `findActiveRole` 결과를 검사하면 된다. 정책 결정이 필요하면 이 지점 하나만 바꾼다.

## 5. 토큰 scope

라이브 토큰에 `scope` 클레임을 추가했다.

- `PLAY`: WHEP 재생. `isPlayable`로 검사한다.
- `TALK`: WHIP 발화. `isTalkable`로 검사하며 유효한 발화 권한을 쥐고 있어야 통과한다.

재생 토큰으로 발화 경로를 통과할 수 없다. Nginx는 경로별로 `scope`를 고정해 introspection에 넘긴다.

`scope`가 없는 토큰은 이 클레임 도입 이전에 발급된 재생 토큰으로 해석한다. 토큰 수명이 30초라 배포 직후 짧은 구간에만 해당한다.

## 6. 미디어 계층 권한

MediaMTX 계정 권한은 다음과 같이 나뉜다.

- 기기 계정: `live/{uuid}` publish, `talkback/{uuid}` read
- Nginx loopback 계정: `live/{uuid}` read, `talkback/{uuid}` publish

기기 계정에 talkback publish 권한은 주지 않는다. Nginx loopback 계정에 live publish 권한도 주지 않는다.

## 7. 기기 도착 전 검증 방법

기기와 스피커가 없는 동안 노트북을 기기 역할로 대체한다.

```
노트북
  ffmpeg(웹캠+마이크) --RTSP publish--> 로컬 MediaMTX(live/{streamId})
  ffplay rtsp://localhost:8554/talkback/{streamId}   ← 스피커 대역
로컬 백엔드 + Mosquitto + PostgreSQL (docker compose)
폰 또는 에뮬레이터에서 Flutter 실행
```

이 구성으로 검증되는 것:

- WHIP 시그널링과 SDP 교환
- `scope=TALK` 토큰 검증과 재생 토큰 거절
- 발화 권한 획득·연장·회수와 동시 발화 거절
- MQTT `START_TALKBACK`/`STOP_TALKBACK` 명령과 ACK
- 앱 푸시투토크 UI와 상태 전이

이 구성으로 검증되지 않는 것:

- 실제 스피커 ALSA 디바이스 선택
- 기기측 에코와 반이중 뮤트의 청감 품질
- LTE·기업망에서의 업링크 NAT 통과율. TURN(Coturn)은 아직 없다.
- Jetson에서의 디코딩 부하

## 8. 남은 하드웨어 의존 작업

- 기기 스피커 구성은 USB 오디오 어댑터, PAM8403 앰프와 수동 스피커를 기준으로 검증한다.
- `bash ai/device_agent/test-speaker-output.sh --list`로 Jetson의 ALSA 출력 장치 이름을 확인한다.
- `bash ai/device_agent/test-speaker-output.sh plughw:CARD=<카드명>,DEV=0 3`으로 낮은 음량의 3초 테스트음을 재생한 뒤 `TALKBACK_OUTPUT_DEVICE`에 같은 장치명을 설정한다.
- 스피커 한 개는 PAM8403의 한 채널 `OUT+`와 `OUT-` 사이에 연결하며, BTL 출력의 `OUT-`를 GND에 연결하지 않는다.
- 실제 장비 시험으로 PAM8403 볼륨 기본 위치와 소프트웨어 음량을 확정한다.
- 반이중 뮤트 전환 시점의 체감 지연 측정
- 실패율이 높으면 Coturn 도입 검토
