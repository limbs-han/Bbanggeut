#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT=/home/ubuntu/william-james
INFRA_ENV="$ROOT/infra/.env"
APP_ENV="$ROOT/secrets/app.env"

if [[ ! -f "$INFRA_ENV" ]]; then
  POSTGRES_PASSWORD="$(openssl rand -hex 32)"
  MINIO_ROOT_PASSWORD="$(openssl rand -hex 32)"
  MQTT_PASSWORD="$(openssl rand -hex 32)"
  MEDIAMTX_PUBLISH_PASSWORD="$(openssl rand -hex 32)"
  MEDIAMTX_JETSON_PUBLISH_PASSWORD="$(openssl rand -hex 32)"
  cat > "$INFRA_ENV" <<EOF
POSTGRES_DB=william_james
POSTGRES_USER=william
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
MINIO_ROOT_USER=william-admin
MINIO_ROOT_PASSWORD=$MINIO_ROOT_PASSWORD
MINIO_VIDEO_BUCKET=william-james-videos
MQTT_USERNAME=wj-backend
MQTT_PASSWORD=$MQTT_PASSWORD
MEDIAMTX_PUBLISH_USER=wj-pi-001
MEDIAMTX_PUBLISH_PASSWORD=$MEDIAMTX_PUBLISH_PASSWORD
MEDIAMTX_JETSON_PUBLISH_USER=wj-jetson-001
MEDIAMTX_JETSON_PUBLISH_PASSWORD=$MEDIAMTX_JETSON_PUBLISH_PASSWORD
MEDIAMTX_TLS_CERT_DIR=$ROOT/secrets/mediamtx
MEDIAMTX_RTSP_ENCRYPTION=optional
EOF
fi

# 최소 권한 객체 저장소 계정. 백엔드와 편집 서버가 root 자격증명을 쓰면
# 유출 시 버킷·정책·계정 관리까지 넘어가므로, 각자 자기 버킷만 만지는
# 계정으로 분리한다. 계정 생성·정책 부여는 minio-init이 담당한다.
if ! grep -q '^WJ_BACKEND_ACCESS_KEY=' "$INFRA_ENV"; then
  {
    printf '%s\n' 'WJ_BACKEND_ACCESS_KEY=wj-backend'
    printf 'WJ_BACKEND_SECRET_KEY=%s\n' "$(openssl rand -hex 32)"
  } >>"$INFRA_ENV"
fi

if ! grep -q '^WJ_EDITOR_ACCESS_KEY=' "$INFRA_ENV"; then
  {
    printf '%s\n' 'WJ_EDITOR_ACCESS_KEY=wj-editor'
    printf 'WJ_EDITOR_SECRET_KEY=%s\n' "$(openssl rand -hex 32)"
  } >>"$INFRA_ENV"
fi

# Older servers already have infra/.env. Add only missing keys without rotating
# an existing credential or printing any secret.
if ! grep -q '^MEDIAMTX_JETSON_PUBLISH_USER=' "$INFRA_ENV"; then
  printf '%s\n' 'MEDIAMTX_JETSON_PUBLISH_USER=wj-jetson-001' >>"$INFRA_ENV"
fi
if ! grep -q '^MEDIAMTX_JETSON_PUBLISH_PASSWORD=' "$INFRA_ENV"; then
  printf 'MEDIAMTX_JETSON_PUBLISH_PASSWORD=%s\n' "$(openssl rand -hex 32)" >>"$INFRA_ENV"
fi
if ! grep -q '^MEDIAMTX_TLS_CERT_DIR=' "$INFRA_ENV"; then
  printf 'MEDIAMTX_TLS_CERT_DIR=%s\n' "$ROOT/secrets/mediamtx" >>"$INFRA_ENV"
fi
if ! grep -q '^MEDIAMTX_RTSP_ENCRYPTION=' "$INFRA_ENV"; then
  printf '%s\n' 'MEDIAMTX_RTSP_ENCRYPTION=optional' >>"$INFRA_ENV"
fi

# Values are generated as hex and are safe to source as simple assignments.
source "$INFRA_ENV"

if [[ ! -f "$APP_ENV" ]]; then
  JWT_SIGNING_KEY="$(openssl rand -hex 48)"
  cat > "$APP_ENV" <<EOF
SPRING_PROFILES_ACTIVE=demo
DB_URL=jdbc:postgresql://127.0.0.1:5432/$POSTGRES_DB
DB_USER=$POSTGRES_USER
DB_PASSWORD=$POSTGRES_PASSWORD
JWT_SIGNING_KEY=$JWT_SIGNING_KEY
S3_ENDPOINT=http://127.0.0.1:9000
S3_PUBLIC_ENDPOINT=https://i15e201.p.ssafy.io
S3_ACCESS_KEY=$WJ_BACKEND_ACCESS_KEY
S3_SECRET_KEY=$WJ_BACKEND_SECRET_KEY
S3_BUCKET=$MINIO_VIDEO_BUCKET
MQTT_BROKER_URL=tcp://127.0.0.1:1883
MQTT_CLIENT_ID=wj-backend-prod
MQTT_USERNAME=$MQTT_USERNAME
MQTT_PASSWORD=$MQTT_PASSWORD
MQTT_ENV=prod
WEBRTC_BASE_URL=https://i15e201.p.ssafy.io/webrtc/live
TALKBACK_WHIP_BASE_URL=https://i15e201.p.ssafy.io/webrtc/talkback
MEDIAMTX_API_BASE_URL=http://127.0.0.1:9997
FFMPEG_PATH=/usr/bin/ffmpeg
EOF
fi

if ! grep -q '^WEBRTC_BASE_URL=' "$APP_ENV"; then
  printf '%s\n' 'WEBRTC_BASE_URL=https://i15e201.p.ssafy.io/webrtc/live' >>"$APP_ENV"
fi

if ! grep -q '^TALKBACK_WHIP_BASE_URL=' "$APP_ENV"; then
  printf '%s\n' \
    'TALKBACK_WHIP_BASE_URL=https://i15e201.p.ssafy.io/webrtc/talkback' >>"$APP_ENV"
fi

if ! grep -q '^MEDIAMTX_API_BASE_URL=' "$APP_ENV"; then
  printf '%s\n' 'MEDIAMTX_API_BASE_URL=http://127.0.0.1:9997' >>"$APP_ENV"
fi

# 이미 root 자격증명으로 발급된 app.env를 최소 권한 계정으로 옮긴다.
# (버킷 정책은 minio-init이 부여하므로 여기서는 키만 바꾼다.)
if grep -q "^S3_ACCESS_KEY=$MINIO_ROOT_USER\$" "$APP_ENV"; then
  sed -i "s|^S3_ACCESS_KEY=.*|S3_ACCESS_KEY=$WJ_BACKEND_ACCESS_KEY|" "$APP_ENV"
  sed -i "s|^S3_SECRET_KEY=.*|S3_SECRET_KEY=$WJ_BACKEND_SECRET_KEY|" "$APP_ENV"
  echo "Backend object storage credentials moved off the MinIO root account."
fi

if ! grep -q '^S3_EDIT_BUCKET=' "$APP_ENV"; then
  printf 'S3_EDIT_BUCKET=%s\n' "${MINIO_EDIT_BUCKET:-william-james-edit}" >>"$APP_ENV"
fi

chmod 600 "$INFRA_ENV" "$APP_ENV"
echo "Secret files are present with mode 600; values were not printed."
