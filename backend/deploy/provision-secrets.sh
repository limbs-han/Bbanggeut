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
  cat > "$INFRA_ENV" <<EOF
POSTGRES_DB=william_james
POSTGRES_USER=william
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
MINIO_ROOT_USER=william-admin
MINIO_ROOT_PASSWORD=$MINIO_ROOT_PASSWORD
MINIO_VIDEO_BUCKET=william-james-videos
MQTT_USERNAME=wj-backend
MQTT_PASSWORD=$MQTT_PASSWORD
EOF
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
S3_ACCESS_KEY=$MINIO_ROOT_USER
S3_SECRET_KEY=$MINIO_ROOT_PASSWORD
S3_BUCKET=$MINIO_VIDEO_BUCKET
MQTT_BROKER_URL=tcp://127.0.0.1:1883
MQTT_CLIENT_ID=wj-backend-prod
MQTT_USERNAME=$MQTT_USERNAME
MQTT_PASSWORD=$MQTT_PASSWORD
MQTT_ENV=prod
MEDIA_BASE_URL=https://i15e201.p.ssafy.io/live
FFMPEG_PATH=/usr/bin/ffmpeg
EOF
fi

chmod 600 "$INFRA_ENV" "$APP_ENV"
echo "Secret files are present with mode 600; values were not printed."
