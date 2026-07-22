# IoT / live streaming integration status

## Implemented in this repository

- Spring creates a per-viewing-session `streamId` and publishes
  `START_STREAM`, `EXTEND_STREAM`, and `STOP_STREAM` commands over MQTT.
- The device agent subscribes to its command topic over MQTTS and starts one
  FFmpeg process at `MEDIA_PUBLISH_URL_TEMPLATE`, replacing `{stream_id}` at
  runtime. Duplicate commands are idempotent and another simultaneous stream
  is rejected with `DEVICE_BUSY`.
- The agent publishes command acknowledgements and
  `STREAM_STARTING/READY/ERROR/STOPPED/HARD_EXPIRED` events. The edge lease is
  enforced even if the backend disappears.
- MediaMTX converts the dynamic RTSP path to HLS. Nginx protects the HLS URL
  through Spring introspection and Flutter creates, heartbeats, plays, and
  closes the stream session.
- Provisioning grants device ACLs for status, heartbeat, detection events,
  stream events, command acknowledgements, and the command subscription.
- The backend now subscribes to and validates detection events and command
  acknowledgements. Detection events are logged only; the uploaded video API
  is still the durable record.

## Not integrated yet

- The laughter detector is not part of this device-agent process. Its current
  MQTT output must not run concurrently with the agent using the same
  credential: provisioning pins the MQTT client ID to `deviceId`, so a second
  connection will disconnect or reject the first one.
- The recommended first integration is one cloud MQTT owner per device. Run
  inference inside the agent process, or send detections to it over a local
  IPC queue/socket and let the agent publish `/events`. Do not copy the device
  bearer token into multiple model processes.
- Event recording is not wired to detection yet. On `LAUGHTER`, the edge must
  lock a pre/post-roll clip, obtain an upload URL from Spring, upload the file,
  and complete the video metadata request. MQTT is notification/control, not
  the video transport.
- `STREAM_READY` currently means that FFmpeg stayed alive for a short startup
  delay. It does not yet probe MediaMTX/HLS readiness.
- Existing provisioned devices do not receive newly added ACL entries
  automatically. Re-enroll/rotate them or add a Dynamic Security ACL migration.

## Deployment blockers and order

1. For the current single-Jetson deployment, install `wj-media-tunnel.service`;
   it reaches the loopback-only MediaMTX port without exposing RTSP publicly.
   Before scaling to multiple devices, replace this with authenticated external
   ingest (prefer RTSPS or SRT) and per-device media credentials.
2. Put the operating credential and broker CA on the Jetson, configure its
   camera/encoder arguments, and enable `wj-device-agent.service`.
3. Re-provision the test device so its MQTT role contains the new event/ACK
   ACLs.
4. Verify the complete path: Flutter create -> MQTT START -> dynamic RTSP
   publish -> MQTT READY -> protected HLS playback -> heartbeat/STOP.
5. Replace the startup-delay READY check with a MediaMTX API or HLS playlist
   health probe, and confirm that the HLS viewer token remains valid for a long
   viewing session.
6. Merge laughter inference through local IPC or the same process, then add the
   pre-roll buffer, clip lifecycle, retryable upload queue, and backend event
   persistence/idempotency.
7. Add service metrics, disk quota/retention, credential rotation, and
   reconnect/reboot integration tests before unattended deployment.

## Detection event shape

The integrated publisher should send this through the single device-agent MQTT
connection:

```json
{
  "schemaVersion": "1.0",
  "eventId": "<uuid>",
  "deviceId": "<uuid>",
  "type": "LAUGHTER",
  "occurredAt": "2026-07-22T12:34:56.789Z",
  "confidence": 0.92
}
```

Topic: `prod/wj/v1/devices/{deviceId}/events`, QoS 1. Use `eventId` as the
idempotency key when persistence is added.
