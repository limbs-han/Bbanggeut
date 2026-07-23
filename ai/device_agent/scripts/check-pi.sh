#!/usr/bin/env bash
set -euo pipefail

env_file=/etc/william-james/device-agent.env
ca_file=/etc/william-james/certs/mqtt-ca.crt

echo "[device-agent]"
systemctl is-enabled wj-device-agent
systemctl is-active wj-device-agent
journalctl -u wj-device-agent -n 20 --no-pager |
  grep -E "device agent started|MQTT connected|MQTT connection rejected|MQTT disconnected" ||
  true

echo
echo "[safe MQTT configuration]"
grep -E '^(DEVICE_ID|MQTT_HOST|MQTT_PORT|MQTT_ENV|MQTT_CA_CERT)=' "$env_file"
test -s "$ca_file"
openssl x509 -in "$ca_file" -noout -subject -issuer -dates

echo
echo "[local MediaMTX]"
systemctl is-active mediamtx
ss -ltn 'sport = :8554'

echo
echo "[camera publisher]"
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
  echo "Publisher is inactive. Connect/configure the camera, then start homecam-publisher."
fi
