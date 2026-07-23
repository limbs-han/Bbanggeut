#!/usr/bin/env bash
set -euo pipefail

env_file=/etc/william-james/device-agent.env
ca_file=/etc/william-james/certs/mqtt-ca.crt

echo "[기기 에이전트]"
systemctl is-enabled wj-device-agent
systemctl is-active wj-device-agent
journalctl -u wj-device-agent -n 20 --no-pager |
  grep -E "기기 에이전트 시작|MQTT 연결|MQTT connection|device agent" ||
  true

echo
echo "[비밀값을 제외한 MQTT 설정]"
grep -E '^(DEVICE_ID|MQTT_HOST|MQTT_PORT|MQTT_ENV|MQTT_CA_CERT)=' "$env_file"
test -s "$ca_file"
openssl x509 -in "$ca_file" -noout -subject -issuer -dates

echo
echo "[Pi 내부 MediaMTX]"
systemctl is-active mediamtx
ss -ltn 'sport = :8554'

echo
echo "[카메라 publisher]"
systemctl is-enabled homecam-publisher
systemctl is-active homecam-publisher || true
if systemctl is-active --quiet homecam-publisher; then
  ffprobe \
    -v error \
    -rtsp_transport tcp \
    -show_entries stream=codec_type,codec_name,width,height \
    -of default=noprint_wrappers=1 \
    rtsp://127.0.0.1:8554/homecam
else
  echo "Publisher가 비활성 상태입니다. 카메라를 연결·설정한 뒤 homecam-publisher를 시작하세요."
fi
