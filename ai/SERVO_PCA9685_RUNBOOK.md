# Jetson Orin Nano + PCA9685 + SG90 자동 프레이밍 실행 절차

## 1. 설계 기본 규격

| 항목 | 값 |
| --- | --- |
| Jetson | Orin Nano 공식 Developer Kit |
| OS | Jetson Linux R36.4.7, Ubuntu 22.04 |
| 카메라 | Logitech BRIO 100, 1280×720, 30FPS |
| 객체 | COCO `person`, `cat`, `dog` |
| AI | YOLOv8n + ByteTrack |
| MQTT broker | Jetson의 `127.0.0.1:1883` |
| PCA9685 | 기본 주소 `0x40`, 50Hz |
| PAN | Channel 0, HOME 기준 `-40°~+40°` |
| TILT | Channel 1, 수평 HOME `0°`, 아래 방향 최대 `+80°` |
| AI 발행 주기 | 10Hz |
| 목표 메시지 TTL | 500ms |
| 대상 소실 | 5초 `HOLD` 후 `HOME` |

AI는 각도와 PWM을 직접 만들지 않는다. AI가 화면 기준 정규화 오차와 두 축
명령을 발행하고, 별도 `servo_controller.py`가 물리 한계·속도·펄스 보정을
담당한다.

### 2026-07-29 Jetson 실물 검증 프로필

아래 값은 현재 Jetson과 카메라 기구물에서 실제 검증한 초기 안전값이다.
새 PCA9685나 SG90으로 교체하면 다시 보정한다.

| 항목 | 검증값 |
| --- | --- |
| I2C | bus 7, address `0x60` |
| 외부 서보 전원 | Battery Shield V9, 동시 구동 중 5.17V |
| PAN | Channel 0, `-10°~+10°`, pulse direction `-1` |
| TILT | Channel 1, `0°~+10°`, pulse direction `-1` |
| HOME | 두 축 모두 1500us |
| 객체 정책 | 복수 객체의 그룹 중앙 추적 |
| 최종 dead zone | width/height `0.08` |
| 대상 소실 | 5초 뒤 HOME 실물 복귀 확인 |

상세 시험 결과와 다음 작업은
`SERVO_OBJECT_TRACKING_HANDOFF_20260729.txt`에 기록했다.

## 2. 전원 안전 조건

> 별도의 안정적인 5V 서보 전원이 준비되기 전에는
> `SERVO_ENABLE_HARDWARE=true`로 바꾸지 않는다.

- Jetson과 PCA9685 사이에는 3.3V 로직 전원, SDA, SCL, GND만 연결한다.
- SG90용 `V+`는 Jetson의 5V 핀에서 공급하지 않는다.
- SG90 두 개에는 정전압 5V 3A급 외부 전원을 권장한다.
- Jetson GND, PCA9685 GND, 외부 5V 전원의 `-`는 반드시 공통으로 연결한다.
- PCA9685의 `VCC`와 서보 전원 `V+`를 혼동하지 않는다.
- 배선을 바꿀 때는 Jetson과 외부 5V 전원을 모두 끈다.

## 3. J12와 PCA9685 연결

Jetson Orin Nano 공식 캐리어 보드의 40핀 확장 헤더는 J12다.

| Jetson J12 | PCA9685 | 용도 |
| --- | --- | --- |
| Pin 1, 3.3V | `VCC` | PCA9685 로직 전원 |
| Pin 3, I2C1 SDA | `SDA` | I2C 데이터 |
| Pin 5, I2C1 SCL | `SCL` | I2C 클록 |
| Pin 6, GND | `GND` | 로직·전원 공통 GND |
| 연결하지 않음 | `V+` | 아래 외부 5V 전원에서 공급 |

외부 전원이 준비된 뒤에만 다음을 연결한다.

| 외부 5V 전원 | 연결 |
| --- | --- |
| `+5V` | PCA9685 터미널 `V+` |
| `-` | PCA9685 `GND` |

SG90 커넥터는 일반적으로 갈색/검정이 GND, 빨강이 V+, 주황/노랑이
PWM 신호다. 실제 제품의 배선 표기를 먼저 확인한다.

NVIDIA J12 규격:
<https://developer.nvidia.com/downloads/assets/embedded/secure/jetson/orin_nano/docs/jetson_orin_nano_devkit_carrier_board_specification_sp.pdf>

PCA9685 전원 설명:
<https://learn.adafruit.com/16-channel-pwm-servo-driver/hooking-it-up>

## 4. I2C 주소 확인

서보와 외부 `V+`를 연결하지 않은 상태에서도 PCA9685의 `VCC`, SDA, SCL,
GND만으로 I2C 주소를 확인할 수 있다.

```bash
sudo apt-get install -y i2c-tools
i2cdetect -l
ls -l /dev/i2c-*
getent group i2c
```

J12 Pin 3/5에 대응하는 버스 번호는 Jetson Linux 열거 상태에 따라 달라질 수
있으므로 추측하지 않는다. 후보 버스를 찾은 뒤 다음처럼 조회한다.

```bash
sudo i2cdetect -y 7
```

정상적인 기본 PCA9685라면 표에 `40`이 나타난다. 실제 버스가 7이 아니라면
확인된 번호를 사용한다. `UU` 또는 다른 주소가 나오면 하드웨어 출력을
활성화하기 전에 원인을 확인한다.

수동 Python 실행에 I2C 권한이 없다면 서비스 계정에 `i2c` 보조 그룹을
추가하고 SSH에 다시 로그인한다.

```bash
sudo usermod -aG i2c ssafy
```

## 5. Python 의존성

기존 YOLO 가상환경을 그대로 사용한다. Jetson 전용 PyTorch를 재설치하지
않는다.

```bash
source ~/venvs/yolo/bin/activate
python -m pip install -r ~/ai/yolo/requirements-servo-controller.txt
python -c 'import paho.mqtt.client, smbus2; print("servo dependencies: OK")'
```

## 6. MQTT 메시지

목표 토픽:

```text
homecam/v2/{device_id}/control/framing/target
```

상태 토픽:

```text
homecam/v2/{device_id}/control/framing/status
```

추적 예시:

```json
{
  "schema_version": "1.1",
  "device_id": "11111111-1111-4111-8111-111111111111",
  "sent_at": "2026-07-28T03:30:00.000Z",
  "sequence": 1251,
  "state": "TRACKING",
  "direction": "RIGHT_DOWN",
  "command_x": "RIGHT",
  "command_y": "DOWN",
  "error_x": 0.18,
  "error_y": 0.12,
  "target_ids": [1, 4],
  "ttl_ms": 500
}
```

축 규칙:

```text
error_x < 0: 화면 왼쪽
error_x > 0: 화면 오른쪽
error_y < 0: 화면 위쪽
error_y > 0: 화면 아래쪽
```

상태 처리 우선순위:

1. `HOME` 또는 `RETURN_HOME`: 보정된 수평 HOME으로 속도 제한 복귀
2. `HOLD` 또는 `NO_TARGET_HOLD`: 현재 물리 위치 유지, 오차값 무시
3. `TRACKING`: `command_x`, `command_y`, `error_x`, `error_y`로 점진 이동

`HOLD` 메시지에는 마지막 오차가 진단 목적으로 남지만 모터 제어에는 사용하지
않는다. 500ms가 지난 메시지, 다른 `device_id`, 역순 메시지, 범위를 벗어난
오차는 폐기한다. 정상 메시지가 750ms 이상 끊기면 제어기는 자체적으로
`HOLD`한다.

## 7. 외부 전원 없이 드라이런

`DEVICE_ID`는 실제 장치 환경과 동일하게 설정한다. Bearer token은 출력하거나
복사하지 않는다.

```bash
export DEVICE_ID=11111111-1111-4111-8111-111111111111
~/venvs/yolo/bin/python -u ~/ai/yolo/servo_controller.py \
  --no-enable-hardware
```

다른 SSH 터미널에서 상태 메시지를 확인한다.

```bash
mosquitto_sub -h 127.0.0.1 -p 1883 \
  -t "homecam/v2/${DEVICE_ID}/control/framing/status" -v
```

YOLO 실행 로그에서 다음을 확인한다.

```text
Framing target MQTT: homecam/v2/.../control/framing/target
```

드라이런 로그의 PAN은 `-40~+40`, TILT는 `0~+80` 범위를 벗어나면 안 된다.

## 8. 실물 보정

외부 5V 전원과 공통 GND를 확인한 뒤에도 처음부터 전체 범위를 사용하지 않는다.

1. 카메라 기구물이 물리적 끝각에 닿지 않도록 손으로 가동 범위를 확인한다.
2. `SERVO_PAN_MIN_DEG=-10`, `SERVO_PAN_MAX_DEG=10`,
   `SERVO_TILT_MAX_DEG=10`으로 시작한다.
3. PAN/TILT HOME 펄스는 각각 1500us에서 시작한다.
4. HOME이 수평·정면이 아니면 해당 축의 `*_HOME_PULSE_US`를 작은 단위로
   조정한다.
5. RIGHT 명령에서 왼쪽으로 움직이면 `SERVO_PAN_PULSE_DIRECTION` 부호를
   반대로 바꾼다.
6. DOWN 명령에서 위쪽으로 움직이면 `SERVO_TILT_PULSE_DIRECTION` 부호를
   반대로 바꾼다.
7. ±10° 시험을 통과한 뒤 PAN ±20°, ±30°, ±40° 순서로 확대한다.
8. TILT는 아래 방향 20°, 40°, 60°, 80° 순서로 확대한다.
9. 떨림·소음·기구물 충돌이 발생하면 즉시 외부 5V 전원을 끈다.

기본 보정 환경변수:

```text
SERVO_I2C_ADDRESS=0x40
SERVO_PAN_CHANNEL=0
SERVO_TILT_CHANNEL=1
SERVO_PAN_MIN_DEG=-40
SERVO_PAN_MAX_DEG=40
SERVO_TILT_MIN_DEG=0
SERVO_TILT_MAX_DEG=80
SERVO_PAN_HOME_PULSE_US=1500
SERVO_TILT_HOME_PULSE_US=1500
SERVO_PAN_PULSE_DIRECTION=1
SERVO_TILT_PULSE_DIRECTION=1
SERVO_MINIMUM_PULSE_US=1000
SERVO_MAXIMUM_PULSE_US=2000
```

TILT HOME을 기준으로 위·아래 이동량을 같게 쓰려면 기구물의 양방향
여유를 먼저 확인한 뒤 `SERVO_TILT_MIN_DEG=-20`,
`SERVO_TILT_MAX_DEG=20`처럼 HOME `0`을 중심으로 대칭 범위를 설정한다.
카메라의 UP/DOWN 명령과 실제 움직임이 반대라면
`SERVO_TILT_PULSE_DIRECTION`을 `1`과 `-1` 중 반대 값으로 변경한다.

## 9. 하드웨어 출력 활성화

아래 조건을 모두 만족한 뒤에만 진행한다.

- 외부 정전압 5V 전원 연결
- 모든 GND 공통 확인
- `i2cdetect`에서 PCA9685 주소 확인
- 서보 커넥터 극성 확인
- PAN/TILT 축별 HOME과 방향 설정
- 초기 가동 범위 ±10°/10° 제한

`/etc/william-james/device-agent.env`에 실제 값을 기록한다.

```text
SERVO_ENABLE_HARDWARE=true
SERVO_I2C_BUS=확인한_버스_번호
```

서비스를 설치한 경우 다음 순서로 확인한다.

```bash
sudo systemctl daemon-reload
sudo systemctl start wj-servo-controller
sudo journalctl -u wj-servo-controller -f
```

이 프로젝트의 Device/AI 정책상 서비스 설치와 실제 Jetson 실행은 작업자가
명시적으로 수행하며 자동 배포하지 않는다.

## 10. 즉시 정지와 복구

비정상 움직임이 발생하면 소프트웨어 명령보다 먼저 외부 5V 전원을 끈다.

```bash
sudo systemctl stop wj-servo-controller
```

다시 드라이런으로 전환:

```text
SERVO_ENABLE_HARDWARE=false
```

```bash
sudo systemctl restart wj-servo-controller
```

서비스가 정상 종료되면 PCA9685 Channel 0/1 출력을 `FULL OFF`로 전환한다.
