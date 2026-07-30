# Raspberry Pi 기기 등록 및 직접 RTSPS 구성 가이드

이 문서는 기기·MQTT·MediaMTX 비밀값을 Git에 저장하지 않으면서 실제
Raspberry Pi의 제어 및 미디어 구성을 처음부터 재현하는 절차를 설명합니다.

## 최종 구성

```text
EC2 Spring 백엔드
  -> TLS 8883 포트로 MQTT START_STREAM 명령 전송
  -> Raspberry Pi wj-device-agent
  -> rtsp://127.0.0.1:8554/homecam 읽기
  -> 인증된 RTSPS로 EC2 8322 포트에 송출
  -> EC2 MediaMTX가 Flutter용 보호된 WebRTC/WHEP 재생 경로 제공

USB 카메라
  -> homecam-publisher
  -> Raspberry Pi 내부 전용 MediaMTX
```

Pi는 SSH 미디어 터널을 열지 않습니다. MQTT와 RTSPS는 Pi가 각각 시작하는
별도의 TLS 연결입니다.

## Git에 저장하면 안 되는 값

저장소에는 코드, 예제 설정, systemd 서비스와 공개 서버 주소만 저장합니다.
다음 값은 절대 커밋하지 않습니다.

- `DEVICE_PROVISIONING_ADMIN_KEY`
- bootstrap 또는 operating bearer token
- MediaMTX 송출 비밀번호
- SSH 개인키
- 실제 값이 입력된 `/etc/william-james/*.env` 파일

## 1. Bootstrap 토큰을 발급하기 전에 Pi 준비

저장소를 clone하고 MQTT CA 인증서와 함께 설치 스크립트를 실행합니다.
설치 스크립트는 64비트 ARM Raspberry Pi OS를 지원하며 로컬 검증을 위해
x86-64도 인식합니다.

```bash
git clone https://lab.ssafy.com/s15-webmobile3-sub1/S15P11E201.git
cd S15P11E201/ai/device_agent

chmod +x scripts/*.sh homecam-publisher.sh
sudo ./scripts/prepare-pi.sh /path/to/mqtt-ca.crt
```

설치되는 항목:

- `/opt/william-james/device-agent`의 Python 기기 에이전트
- 공개된 SHA-256 체크섬을 검증한 MediaMTX v1.18.2
- `127.0.0.1:8554` 내부 전용 RTSP
- `wj-device-agent.service`
- `mediamtx.service`
- `homecam-publisher.service`
- `wj-registration-button.service` (BCM GPIO 17, physical pin 11)
- `/etc/william-james` 아래의 root 소유 예제 설정

`wj-device-agent`는 enrollment 전까지 시작하지 않습니다. MediaMTX는 즉시
시작합니다. 카메라 publisher는 부팅 시 시작하도록 등록하지만 설치 과정에서는
시작하지 않습니다.

## 2. EC2 직접 RTSPS 송출 설정

EC2 인프라 관리자에게 송출 전용 MediaMTX 사용자 이름과 비밀번호를 받습니다.
Pi에서 다음 명령을 실행하고 숨김 입력창에 입력합니다.

```bash
cd ~/S15P11E201/ai/device_agent
sudo ./scripts/configure-pi-rtsps.sh
```

공장 자동화처럼 대화형 입력을 사용할 수 없다면 비밀번호만 들어 있는 권한 600
파일을 만들고 사용자 이름은 별도 인자로 전달합니다.

```bash
chmod 600 /secure/path/mediamtx-password
sudo ./scripts/configure-pi-rtsps.sh \
  --username wj-pi-001 \
  --password-file /secure/path/mediamtx-password
```

도우미는 자격증명을 URL 인코딩한 뒤 `MEDIA_PUBLISH_URL_TEMPLATE`을 원자적으로
교체합니다. 비밀번호나 완성된 송출 URL은 출력하지 않습니다.

## 3. EC2에서 미등록 기기 생성

Pi 준비가 끝난 뒤에만 실행합니다. Bootstrap 토큰은 짧은 시간 안에 만료됩니다.
먼저 Pi에서 하드웨어 일련번호를 확인합니다.

```bash
awk -F ': ' '/^Serial/ {print $2}' /proc/cpuinfo
```

그 값을 `--serial`에 넣고 내부 API에 접근할 수 있는 EC2에서 실행합니다.

```bash
cd ~/william-james/ai/device_agent
set -a
source ~/william-james/secrets/app.env
set +a

./scripts/create-device-on-server.sh \
  --serial "WJ-PI-10000000E127F417" \
  --name "거실 Raspberry Pi" \
  --model "Raspberry Pi 4" \
  --token-out /secure/path/wj-bootstrap.token
```

도우미는 기기 ID와 만료 시각만 출력합니다. Bearer token은 지정한 권한 600
파일에만 쓰며 기존 파일을 덮어쓰지 않습니다.

생성된 토큰 파일 하나만 승인된 보안 경로로 Pi의
`/home/pi/wj-bootstrap.token`에 전달합니다. 토큰을 셸 기록이나 채팅에
붙여 넣지 않습니다.

## 4. Enrollment, MQTT 시작, Flutter 등록

Pi에서 실행합니다.

```bash
chmod 600 /home/pi/wj-bootstrap.token
cd ~/S15P11E201/ai/device_agent
sudo ./scripts/enroll-pi.sh /home/pi/wj-bootstrap.token
```

스크립트가 수행하는 작업:

1. HTTPS로 일회용 bootstrap 자격증명을 교환합니다.
2. 운영용 기기 ID와 bearer token을 권한 600으로 원자적 저장합니다.
3. 교환에 성공하면 bootstrap token 파일을 삭제합니다.
4. MQTT CA와 실행 설정을 검증합니다.
5. `wj-device-agent`를 활성화하고 시작합니다.
6. Flutter에 입력할 2분짜리 등록 코드를 출력합니다.

코드를 앱에 즉시 입력합니다. Enrollment는 기계 자체를 인증하고, 등록 코드는
그 기계를 사용자 계정에 연결합니다.

## 5. USB 카메라 연결 및 시작

실제 캡처 장치와 지원 모드를 확인합니다.

```bash
v4l2-ctl --list-devices
v4l2-ctl --device=/dev/video0 --list-formats-ext
ls -l /dev/v4l/by-id/ 2>/dev/null || true
```

가능하면 `/dev/v4l/by-id/...-video-index0`처럼 재부팅 후에도 유지되는 경로를
사용합니다. 다음 설정 파일을 수정합니다.

```bash
sudoedit /etc/william-james/homecam-publisher.env
```

Publisher를 시작하고 확인합니다.

```bash
sudo systemctl start homecam-publisher
sudo systemctl status homecam-publisher mediamtx --no-pager -l

ffprobe -v error -rtsp_transport tcp \
  -show_entries stream=codec_type,codec_name,width,height \
  -of default=noprint_wrappers=1 \
  rtsp://127.0.0.1:8554/homecam
```

Flutter 라이브 화면을 시험하기 전에 로컬 스트림에서 H.264가 확인되어야 합니다.
`/dev/video0`이 없고 `rpicam-vid --list-cameras`도 카메라를 찾지 못하는 보드는
MQTT enrollment까지는 가능하지만 영상을 송출할 수 없습니다.

## 6. Pi 전체 설정 검증

```bash
cd ~/S15P11E201/ai/device_agent
sudo ./scripts/check-pi.sh
```

정상 MQTT 로그:

```text
MQTT 연결 및 명령 구독 활성화 완료
```

Flutter에서 카메라를 열면서 다음 로그를 확인합니다.

```bash
sudo journalctl -u wj-device-agent -f
sudo journalctl -u mediamtx -f
```

기기 에이전트는 `START_STREAM`을 수신하고 릴레이 FFmpeg 프로세스 하나를 시작한
뒤 `STREAM_READY`를 발행해야 합니다. 항상 실행되는 `homecam-publisher`만
물리 카메라를 직접 엽니다.

## 자격증명 갱신

`DEVICE_CREDENTIAL_EXPIRES_AT` 전에 운영용 자격증명을 갱신하고 서비스를
재시작합니다.

```bash
sudo /opt/william-james/device-agent/venv/bin/python \
  -m wj_device_agent.provision \
  --api-base-url https://i15e201.p.ssafy.io \
  --env-file /etc/william-james/device-agent.env \
  rotate

sudo systemctl restart wj-device-agent
```

갱신하면 해당 기기의 API bearer token과 Mosquitto 비밀번호가 함께 바뀝니다.
Flutter에서 기기를 다시 등록할 필요는 없습니다.

## 보안 정리

검증이 끝난 뒤 다음을 수행합니다.

- 전달에 사용한 bootstrap 및 임시 비밀번호 파일을 삭제합니다.
- 공장 출하 또는 기본 Pi 비밀번호를 변경합니다.
- `/etc/william-james/device-agent.env` 권한을 600으로 유지합니다.
- MediaMTX 송출 자격증명을 명령행 인자와 로그에 남기지 않습니다.
- Pi 내부 전용 MediaMTX 포트를 LAN이나 인터넷에 노출하지 않습니다.
