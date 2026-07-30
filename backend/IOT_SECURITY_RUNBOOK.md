# IoT credential and broker runbook

## Device enrollment flow

1. An operator calls `POST /internal/admin/devices`. The returned bearer token has
   purpose `BOOTSTRAP`, expires after 15 minutes by default, and is not accepted by
   operating IoT APIs or MQTT.
2. The device calls `POST /api/iot/enrollment` once with that bearer token. The
   response contains the `OPERATING` bearer token and its expiry.
3. For both HTTP and MQTT, the MQTT password is the returned `bearerToken`. MQTT
   uses `mqttUsername` as both the username and MQTT client ID. The broker creates
   an exact per-device ACL: publish only to the four device event topics and
   subscribe/receive only from that device's `commands` topic.
4. Before expiry, the device calls `POST /api/iot/credentials/rotate` with its
   current operating bearer token and atomically replaces its HTTP and MQTT secret.
   A successful rotation disconnects MQTT sessions using the old password.

The plaintext secret is returned only in the enrollment/rotation response. The
database stores only SHA-256 and Mosquitto stores its own password verifier.

## Local broker

Create a strong `MQTT_PASSWORD` in `backend/.env`, then generate a local CA and
server certificate:

```powershell
./infra/mosquitto/generate-dev-certs.ps1
```

Start Compose and set the backend variables to the same broker administrator
credentials. Trust the generated CA explicitly:

```text
MQTT_BROKER_URL=ssl://localhost:8883
MQTT_USERNAME=wj-backend-local
MQTT_PASSWORD=<same strong value as Compose>
MQTT_TLS_CA_PATH=<absolute path>/infra/mosquitto/certs/ca.crt
```

Port 1883 is intentionally absent. Do not add an anonymous or plaintext listener.

## Production requirements

- Mount a CA-issued Mosquitto server certificate directory through
  `MQTT_TLS_CERT_DIR`; it must contain `ca.crt`, `server.crt`, and `server.key`.
- Keep the Mosquitto Dynamic Security data volume persistent. Changing the backend
  administrator password requires rotating that client in Dynamic Security too.
- The base production Compose keeps MinIO private and anonymous bucket access
  disabled, but does not invent placeholder KES/KMS credentials. Provision a
  production KES/KMS first, then enable bucket-default SSE-KMS through a reviewed
  production override and server-owned secrets. Do not make the base deployment
  depend on an external KMS that has not actually been provisioned.
- Keep PostgreSQL, MinIO API/console, RTSP and MediaMTX control ports bound to
  loopback or a private container network unless an authenticated TLS proxy is in
  front of them.
