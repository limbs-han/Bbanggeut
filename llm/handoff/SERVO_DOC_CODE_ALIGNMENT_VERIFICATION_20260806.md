# 서보 문서·코드 정합화 실물 검증 체크리스트

작성일: 2026-08-06 (KST)
대상 브랜치의 변경: 런북/env example/대시보드 눈금 정합화, `SIGUSR1` 무장 거부
조건 추가, `SERVO_NOMINAL_MESSAGE_INTERVAL_SECONDS` 노출, `TimeoutStopSec` 상향.

이 문서는 **작업자가 직접 실행**한다. 저장소 정책상 서비스 설치와 젯슨 실행은
자동화하지 않는다(`ai/SERVO_PCA9685_RUNBOOK.md` §9).

## 0. 안전 규칙

- 떨림·기구물 충돌·큰 소음이 생기면 **소프트웨어보다 배터리 실드 5V OFF가
  먼저**다. 그 다음 `sudo systemctl stop wj-servo-controller`.
- 1~3단계는 배터리 실드 **OFF** 상태에서 한다. PWM 신호만 확인하는 단계이고,
  기대 결과가 "출력이 없어야 한다"인 항목이 섞여 있다.
- 4~5단계에서만 실드를 켠다.
- `/etc/william-james/device-agent.env`의 토큰과 비밀번호는 출력하거나 복사하지
  않는다.

## 1. 드라이런: 상태 전이와 각도 범위

배터리 실드 OFF. 서비스와 충돌하지 않도록 먼저 정지한 뒤 수동 실행한다.

```bash
sudo systemctl stop wj-servo-controller
export DEVICE_ID="$(sudo grep -m1 '^DEVICE_ID=' /etc/william-james/device-agent.env | cut -d= -f2-)"
( mosquitto_sub -h 127.0.0.1 -p 1883 \
    -t "homecam/v2/${DEVICE_ID}/control/framing/status" -v \
    | tee ~/servo_verify_20260806_status.log & )
~/venvs/yolo/bin/python -u ~/ai/yolo/servo_controller.py --no-enable-hardware
```

확인할 것:

- 상태가 `HOLD` → 객체가 잡히면 `TRACKING` → 사라지면 `NO_TARGET_HOLD` →
  5초 뒤 `HOME`으로 전이하는지
- `pan_deg`가 `-90~+90`, `tilt_deg`가 `0~+110`을 한 번도 벗어나지 않는지
- `HOME` 상태의 목표가 PARK(`target_pan_deg=0`, `target_tilt_deg=0`)인지.
  상태 이름은 HOME이지만 이동 지점은 PARK가 맞다

## 2. 회귀: 복원 위치가 없으면 SIGUSR1 무장을 거부한다

이번 변경의 핵심 동작이다. 배터리 실드 OFF 유지. 실제 상태 파일은 건드리지
않도록 임시 경로에 **일부러 잘못된** 파일을 만든다.

```bash
sudo systemctl stop wj-servo-controller
export DEVICE_ID="$(sudo grep -m1 '^DEVICE_ID=' /etc/william-james/device-agent.env | cut -d= -f2-)"
printf '{"schema_version":"1.0","device_id":"00000000-0000-4000-8000-000000000000","saved_at_epoch":0,"pan_deg":0,"tilt_deg":0}\n' > /tmp/servo-verify-position.json
SERVO_ENABLE_HARDWARE=true \
SERVO_I2C_BUS=7 \
SERVO_STARTUP_POSITION=persisted \
SERVO_STATE_FILE=/tmp/servo-verify-position.json \
~/venvs/yolo/bin/python -u ~/ai/yolo/servo_controller.py &
sleep 3
sudo kill -s USR1 %1
```

확인할 것:

- 기동 로그에 `servo state file belongs to a different device`와
  `PWM output remains disabled in STARTUP_WAITING`이 뜨는지
- `SIGUSR1` 이후 로그가 **`Servo arm refused: no startup position was
  restored ...`** 인지. 이전에는 여기서 조용히 무장했다
- 상태 토픽의 `state`가 계속 `STARTUP_WAITING`, `output_armed`가 `false`인지
- 서보가 전혀 움직이지 않는지 (실드를 켜서 확인하지는 않는다)

정리:

```bash
kill %1
rm -f /tmp/servo-verify-position.json
```

## 3. 회귀: 기본 park 경로는 종전대로 무장한다

배터리 실드 OFF 유지.

```bash
sudo systemctl stop wj-servo-controller
export DEVICE_ID="$(sudo grep -m1 '^DEVICE_ID=' /etc/william-james/device-agent.env | cut -d= -f2-)"
SERVO_ENABLE_HARDWARE=true \
SERVO_I2C_BUS=7 \
SERVO_STARTUP_POSITION=park \
SERVO_START_ARMED=false \
~/venvs/yolo/bin/python -u ~/ai/yolo/servo_controller.py &
sleep 3
sudo kill -s USR1 %1
```

확인할 것:

- 기동 직후 `Servo startup safety: parked start pan=+0.00deg tilt=+0.00deg`와
  `Servo startup hold: PWM live at ...`가 순서대로 뜨는지
- `SIGUSR1` 이후 `Servo armed: following targets from pan=+0.00deg
  tilt=+0.00deg`가 뜨는지. 2단계와 달리 여기서는 무장돼야 한다

정리: `kill %1`

## 4. PARK를 무전원 정지 위치에 맞춘다 (혼 재체결)

전원을 켤 때 서보가 튀는 원인은 하나다 — PARK 펄스가 가리키는 각도와 무전원
정지 위치가 다르다. 서보에 위치 피드백이 없어 소프트웨어로는 못 막으므로
기구적으로 맞춘다. 런북 §8 "PARK를 무전원 정지 위치에 맞추기" 참조.

배터리 실드 OFF 상태에서 서보 혼과 짐벌 링키지를 분리한 뒤:

```bash
sudo systemctl stop wj-servo-controller
export DEVICE_ID="$(sudo grep -m1 '^DEVICE_ID=' /etc/william-james/device-agent.env | cut -d= -f2-)"
SERVO_ENABLE_HARDWARE=true \
SERVO_I2C_BUS=7 \
SERVO_STARTUP_POSITION=park \
SERVO_START_ARMED=false \
~/venvs/yolo/bin/python -u ~/ai/yolo/servo_controller.py
```

`Servo startup hold: PWM live at pan=+0.00deg tilt=+0.00deg`를 확인한 뒤:

1. 실드를 켠다. 혼에 부하가 없으므로 서보는 자유롭게 PARK로 이동한다.
2. 짐벌을 자연 정지 위치에 둔 채 혼을 다시 체결한다. TILT는 스톱을 계속 밀지
   않도록 스톱에서 1~2° 안쪽에 오게 한다.
3. 실드를 껐다 켠다. **움직이지 않아야 한다.** 여전히 튀면 혼을 한 칸 옮겨
   다시 시도한다.

PAN은 스톱이 없어 무전원 정지 위치가 재현되지 않는다. 혼 체결만으로는 부족하고
5단계의 전원 순서를 함께 지켜야 한다.

## 5. 전원 순서와 실물 기동

여기서 처음 실드를 켠다. 런북 §8의 순서를 지킨다.

```bash
sudo systemctl start wj-servo-controller
sudo journalctl -u wj-servo-controller -f
```

확인할 것:

- `Servo startup hold: PWM live at pan=+0.00deg tilt=+0.00deg`를 **먼저**
  확인한 뒤에 배터리 실드를 켠다
- 실드를 켜는 순간 서보가 튀지 않는지. PARK 펄스를 이미 받고 있으므로
  움직일 이유가 없다

## 6. 종료 시 PARK 복귀 시간 실측

`SERVO_SHUTDOWN_HOME_TIMEOUT_SECONDS=7`, `TimeoutStopSec=12`의 근거를 실측으로
확정한다. 계산상 최악 복귀는 TILT `+110°`를 `20°/s`로 도는 5.5초다.

TILT를 `+110`에 가깝게 보낸 상태(카메라 앞에서 아래쪽에 사람이 오래 서 있으면
된다)를 만든 뒤:

```bash
sudo journalctl -u wj-servo-controller -f --output=short-precise &
mosquitto_sub -h 127.0.0.1 -p 1883 -C 1 -t "homecam/v2/$(sudo grep -m1 '^DEVICE_ID=' /etc/william-james/device-agent.env | cut -d= -f2-)/control/framing/status"
sudo systemctl stop wj-servo-controller
```

확인하고 기록할 것:

- 정지 직전의 `tilt_deg`
- 정지 명령부터 PWM 채널이 꺼질 때까지의 실제 초 (journalctl 타임스탬프)
- 마지막 저장 위치가 PARK(`0`, `0`)에 도달했는지, 아니면 중간에서 끊겼는지

**PARK에 도달하지 못했다면** `SERVO_SHUTDOWN_HOME_TIMEOUT_SECONDS`와
`TimeoutStopSec`을 함께 올린다. 복귀 시간은 `범위 ÷ MAX_SPEED`다.

## 7. 실제 회전 각도 확인

환산율 `11.1111us/°`는 `495~2505us`가 물리 180°를 덮는다는 가정이다. SG90
개체차로 실제는 160~170°일 수 있다. PAN을 논리 `±90°`로 보낸 상태에서
**각도기로 실제 회전각을 재고**, 크게 다르면 `SERVO_*_PULSE_US_PER_DEGREE`
재보정을 별도 건으로 올린다. 논리 각도와 화면 오차의 대응이 여기에 달려 있다.

## 8. 결과 기록

아래를 채워 MR에 남긴다. 2026-08-06 시점에 확인된 항목은 채워 두었다.

| 항목 | 결과 |
| --- | --- |
| 1. 드라이런 상태 전이 | |
| 1. 각도 범위 이탈 | |
| 2. SIGUSR1 무장 거부 | |
| 3. park 경로 무장 | |
| 4. 혼 재체결 후 전원 인가 시 튐 | **없음** (2026-08-06 확인) |
| 5. 실드 인가 시 튐 | **없음** (2026-08-06 확인) |
| 5. PAN 회전 방향 | 펄스 상승 = 왼쪽 → `DIRECTION=-1` (2026-08-06) |
| 5. TILT 회전 방향 | 펄스 상승 = 전방 → `DIRECTION=1` (2026-08-06) |
| 5. 기계적 스윕 한계 | PAN `±90` 통과, TILT `+110`이 짐벌 한계 (2026-08-06) |
| 6. 정지 직전 TILT 각도 | |
| 6. PARK 복귀 실측 시간 | |
| 6. PARK 도달 여부 | |
| 7. PAN 실제 회전 각도 (논리 ±90 명령 시) | |
