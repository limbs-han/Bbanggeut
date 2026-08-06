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
| PCA9685 | 저장소 기본 주소 `0x40`, 50Hz |
| PAN | Channel 0, HOME 기준 `-90°~+90°`, PARK `0°` |
| TILT | Channel 1, HOME 기준 `0°~+110°`, PARK `0°` |
| AI 발행 주기 | 10Hz |
| 목표 메시지 TTL | 500ms |
| 대상 소실 | 5초 `HOLD` 후 `HOME` |

AI는 각도와 PWM을 직접 만들지 않는다. AI가 화면 기준 정규화 오차와 두 축
명령을 발행하고, 별도 `servo_controller.py`가 물리 한계·속도·펄스 보정을
담당한다.

### 2026-07-29 Jetson 실물 검증 프로필

아래는 2026-07-29 당시의 현장 보정 이력이며 **현재 기본값이 아니다.** 위 §1
표와 저장소 기본값이 지금의 기준이고, 이 표는 그때 실물에서 처음 확인한 안전
범위를 남긴 기록이다. 주소가 `0x40`이 아니라 `0x60`인 것은 그 보드의 실제
주소를 `i2cdetect`로 확인한 값이기 때문이며, 주소는 보드마다 다르므로 저장소
기본값을 바꾸지 않고 배포 설정에서 지정한다. 새 PCA9685나 SG90으로 교체하면
다시 보정한다.

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
`../llm/handoff/SERVO_OBJECT_TRACKING_HANDOFF_20260729.txt`에 기록했다.

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

1. `HOME` 또는 `RETURN_HOME`: PARK 각도(두 축 모두 `0°`)로 속도 제한 복귀.
   상태 이름은 `HOME`이지만 이동 지점은 PARK다
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

드라이런 로그의 PAN은 `-90~+90`, TILT는 `0~+110` 범위를 벗어나면 안 된다.

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
7. ±10° 시험을 통과한 뒤 PAN ±20°, ±40°, ±60°, ±90° 순서로 확대한다.
8. TILT는 `0°` 시작에서 `+20°`, `+60°`, `+110°` 순서로 확대한다.
9. 떨림·소음·기구물 충돌이 발생하면 즉시 외부 5V 전원을 끈다.

확대는 `servo_test.py`로 각 단계의 양 끝 펄스를 직접 찍어 확인한다. 추적으로
확인하면 움직임이 프레임 안의 사람에 따라 좌우돼 통제되지 않는다. TILT가 큰
각도로 숙을 때는 USB·전원 케이블이 감기거나 당겨지지 않는지 함께 본다.

2026-08-06 실물에서 PAN `±90°`, TILT `0~+110°`까지 통과했다. TILT는 짐벌
구조상 `+110°`가 한계다.

`SERVO_MINIMUM_PULSE_US`/`SERVO_MAXIMUM_PULSE_US`는 `495~2505`다. **서보가
받아들이지 못할 펄스를 막는 하드웨어 backstop이지 가동 범위 제한이 아니다.**
환산율 `11.1111us/°`에서 이 창이 허용하는 것은 PAN이 HOME 기준 약 `±90.5°`,
TILT가 HOME 기준 `-10.4°~+170.5°`다. 기구물을 지키는 것은 축별
`*_MIN_DEG`/`*_MAX_DEG`이므로 각도 한계를 넓힐 때 위 7~8번 절차를 건너뛰지
않는다.

기본 보정 환경변수:

```text
SERVO_I2C_ADDRESS=0x60
SERVO_PAN_CHANNEL=0
SERVO_TILT_CHANNEL=1
SERVO_PAN_MIN_DEG=-90
SERVO_PAN_MAX_DEG=90
SERVO_TILT_MIN_DEG=0
SERVO_TILT_MAX_DEG=110
SERVO_PAN_PARK_DEG=0
SERVO_TILT_PARK_DEG=0
SERVO_PAN_HOME_PULSE_US=1500
SERVO_TILT_HOME_PULSE_US=611
SERVO_PAN_PULSE_DIRECTION=-1
SERVO_TILT_PULSE_DIRECTION=1
SERVO_PAN_PULSE_US_PER_DEGREE=11.1111
SERVO_TILT_PULSE_US_PER_DEGREE=11.1111
SERVO_MINIMUM_PULSE_US=495
SERVO_MAXIMUM_PULSE_US=2505
SERVO_PAN_RESPONSE_GAIN=22.5
SERVO_TILT_RESPONSE_GAIN=22.5
SERVO_PAN_MAX_SPEED=20
SERVO_TILT_MAX_SPEED=20
SERVO_CONTROL_HZ=20
SERVO_STATUS_INTERVAL_SECONDS=0.5
SERVO_MESSAGE_TIMEOUT_SECONDS=0.75
SERVO_NOMINAL_MESSAGE_INTERVAL_SECONDS=0.1
SERVO_STARTUP_POSITION=park
SERVO_START_ARMED=true
SERVO_STATE_FILE=/var/lib/william-james-servo/position.json
SERVO_STATE_MAX_AGE_SECONDS=604800
SERVO_STATE_SAVE_INTERVAL_SECONDS=0.25
SERVO_SHUTDOWN_HOME_TIMEOUT_SECONDS=7
```

PAN은 `-90~+90`, TILT는 짐벌 구조 때문에 `0~+110`을 사용한다. TILT에 음수
구간이 없는 것은 `0°`가 곧 짐벌의 기계적 스톱이고 거기서 앞으로만 숙일 수
있기 때문이다.

객체가 5초 이상 감지되지 않으면 두 축 모두 `0°` PARK 위치로 속도 제한
복귀한다. 상태 토픽에서 이때의 `state`는 `HOME`이지만 **실제 이동 지점은
PARK다.**

`*_HOME_PULSE_US`는 논리 `0°`가 어느 물리 위치인가를 고정하는 값이다. PAN
`1500us`는 카메라 정면, TILT `611us`는 짐벌 정지 위치이며, 2026-08-06에 혼을
그 위치에 맞춰 물렸다. 환산율 `11.1111us/°`는 `495~2505us`가 물리 180°를
덮는다는 뜻이므로 **논리 각도가 곧 물리 각도다.**

`SERVO_PAN_PULSE_DIRECTION=-1`은 실물에서 확인한 값이다. 이 기구에서는 펄스를
올리면 카메라가 왼쪽을 본다.

`SERVO_NOMINAL_MESSAGE_INTERVAL_SECONDS`는 아직 실제 수신 간격을 잴 수 없는
첫 목표 메시지에 가정하는 간격이다. 발행 측의 `--command-interval`과 같은
값으로 둔다.
카메라의 UP/DOWN 명령과 실제 움직임이 반대라면
`SERVO_TILT_PULSE_DIRECTION`을 `1`과 `-1` 중 반대 값으로 변경한다.

### 부팅 시 급회전 방지

기본값은 `SERVO_STARTUP_POSITION=park`다. 기동 시 저장 파일을 무시하고 PARK
각도(두 축 모두 `0°`)를 초기 위치로 삼은 뒤, MQTT 수신을 시작하기 전에
그 각도의 펄스를 즉시 출력한다. PCA9685는 Jetson 3.3V로 동작하므로 서보용
외부 전원이 꺼져 있어도 펄스는 살아 있다. 따라서 **컨트롤러를 먼저 띄우고
배터리 실드를 나중에 켜면**, 서보는 전원이 들어오는 순간 이미 자기 위치인
PARK를 명령받아 움직이지 않는다.

TILT는 기구적으로 시작 위치가 상단 스톱이고 아래로만 움직일 수 있어, 무전원
정지 위치가 PARK로 결정돼 있다. 저장 파일에 남는 값은 실제 각도가 아니라
**마지막으로 명령한 각도**이므로, 서보가 무전원이던 구간에서는 실제 위치와
갈라진다. PARK 상수가 저장값보다 항상 정확한 이유다.

이 모든 전제는 **PARK 펄스가 실제 무전원 정지 위치와 일치할 때만** 성립한다.
어긋나 있으면 전원을 켜는 순간 그 차이만큼 서보가 자기 최대 속도로 튄다.
아래 절차로 한 번 맞춰 둔다.

### PARK를 무전원 정지 위치에 맞추기 (혼 재체결)

서보에는 위치 피드백이 없다. 컨트롤러는 지금 축이 몇 도인지 읽을 수 없고,
전원이 들어오면 서보는 신호선에 실린 펄스를 향해 **자기 최대 속도로** 달려간다.
소프트웨어 속도 제한은 명령 각도의 변화율만 제한할 뿐 이 구간에는 개입하지
못한다. 따라서 튐을 없애는 방법은 기구적으로 PARK == 정지 위치를 만드는 것
하나뿐이다.

1. 배터리 실드를 끄고 서보 혼과 짐벌 링키지를 분리한다.
2. 컨트롤러를 `SERVO_START_ARMED=false`로 띄워 PARK 펄스만 나가게 한다.
3. 실드를 켠다. 혼에 부하가 없으므로 서보는 PARK 각도로 자유롭게 이동한다.
4. **그 상태에서** 짐벌을 자연 정지 위치에 둔 채 혼을 다시 체결한다.
5. 실드를 껐다 켜서 서보가 움직이지 않는지 확인한다.

TILT는 정지 위치가 곧 기계적 스톱이므로, 스톱을 계속 밀지 않도록 스톱에서
1~2° 안쪽을 PARK로 잡는다.

PAN은 스톱이 없어 무전원 정지 위치가 "마지막으로 놓인 자리"다. 재현성이 없으니
혼 체결만으로는 부족하고, **전원을 내리는 순서**를 지켜야 한다. 서비스가 PARK로
복귀하기 전에 실드를 먼저 끄면 서보가 그 자리에 남고, 다음 기동 때 PARK까지의
차이만큼 튄다.

### 손으로 서보 전원을 켤 때: SERVO_START_ARMED=false

PARK 펄스를 미리 내보내도, 컨트롤러가 곧바로 추적을 시작하면 실드를 켜기까지의
대기 구간에서 명령 각도가 다시 PARK를 떠난다. 서보는 아직 전원이 없어 따라오지
못하므로, 실드를 켜는 순간 그 어긋난 각도로 튄다. 실제로 기동 90초 뒤 PAN이
`0°`에서 하한 `-10°`까지 걸어간 것을 확인했다.

실드를 손으로 켜는 운용에서는 `SERVO_START_ARMED=false`로 둔다. 컨트롤러는
`STARTUP_WAITING` 상태로 PARK 펄스만 유지하고 목표 메시지를 무시한다. 실드를
켠 뒤 `SIGUSR1`을 보내면 그 시점의 위치에서 추적을 시작한다.

```bash
sudo systemctl kill -s USR1 wj-servo-controller
```

부팅 시 실드가 이미 켜져 있는 상시 운용에서는 기본값 `true`가 맞다. 그때는
전원과 신호가 함께 올라오므로 어긋날 구간이 없다.

`SERVO_STARTUP_POSITION=persisted`로 바꾸면 이전 동작으로 돌아간다. 컨트롤러는
동작 중 마지막 명령 각도를 `SERVO_STATE_FILE`에 원자적으로 저장하고, 재시작 후
첫 PWM으로 저장된 PAN/TILT 각도를 그대로 출력한 뒤 다음 제어 주기부터 속도
제한을 적용한다. 서보 전원을 한 번도 끊지 않는 운용에서만 사용한다.

`persisted` 모드에서 상태 파일이 없거나, 다른 기기에서 생성됐거나, 설정 범위를
벗어나거나, `SERVO_STATE_MAX_AGE_SECONDS`보다 오래됐으면 상태는
`STARTUP_WAITING`이 된다.
이때 PCA9685 채널은 비활성 상태를 유지하며 객체 추적 메시지가 들어와도 PWM을
출력하지 않는다. 현재 물리 각도를 확인해 유효한 상태 파일을 만든 뒤 서비스를
재시작해야 한다.

이 상태에서는 `SIGUSR1`을 보내도 무장하지 않고 거부 로그만 남는다. 복원된
시작 위치가 없으면 컨트롤러가 아는 각도는 가정된 PARK뿐이고, 실제 각도가
다르면 무장하는 순간 그 차이만큼 튀기 때문이다. 유효한 상태 파일을 만들어
재시작하거나 `SERVO_STARTUP_POSITION=park`로 되돌린다.

정상적인 서비스 종료에서는 MQTT 수신을 먼저 중단하고
`SERVO_SHUTDOWN_HOME_TIMEOUT_SECONDS` 동안 속도 제한을 지키며 PARK
(두 축 모두 `0°`)로 이동한 뒤 그 위치를 저장하고 PWM 채널을 끈다.

기본값 `7`초는 전체 범위를 담는다. TILT `0~+110`의 최악 복귀 거리가 110°이고
`SERVO_TILT_MAX_SPEED=20`에서 5.5초, PAN은 90°에 4.5초다. 두 축이 함께
움직이므로 최악은 5.5초다. systemd 쪽 `TimeoutStopSec`은 여기에 MQTT 해제와
상태 저장, 채널 차단까지 더해 12초로 둔다.

**속도나 각도 범위를 바꾸면 이 두 값을 다시 계산한다.** 복귀 시간은
`범위 ÷ MAX_SPEED`이고, 부족하면 PARK에 닿기 전에 PWM이 꺼진다.

따라서 전원을 내리는 순서는 **서비스 정지 → PARK 복귀 확인 → 배터리 실드
OFF**다. PARK가 아닌 각도에서 실드를 먼저 끄면 다음 기동 때 서보가 PARK로
급하게 되돌아간다.

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
