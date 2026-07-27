# MediaMTX RTSPS deployment

The production source of truth is `docker-compose.yml` plus `mediamtx.yml`.
Secrets remain in `/home/ubuntu/william-james/infra/.env`, and TLS files remain
outside Git in `/home/ubuntu/william-james/secrets/mediamtx`.

## Server prerequisites

Install these files without copying either private file to a device:

```text
/home/ubuntu/william-james/secrets/mediamtx/server.crt  # leaf plus served chain
/home/ubuntu/william-james/secrets/mediamtx/server.key  # server only, mode 600
```

The leaf certificate SAN must contain `i15e201.p.ssafy.io`. The Jetson receives
only the public CA trust anchor as `mediamtx-ca.crt`. Verify that CA file's
SHA-256 fingerprint through a separate trusted channel:

```bash
openssl x509 -in mediamtx-ca.crt -noout -fingerprint -sha256
```

Do not label the leaf certificate fingerprint as the CA fingerprint. Certificate
renewal must atomically refresh `server.crt` and `server.key`, preserve their
permissions, and reload or restart the MediaMTX container.

## Provision and deploy

`provision-secrets.sh` creates separate Pi and Jetson publish passwords on a
new installation without printing them. On an existing installation, the
legacy `MEDIAMTX_PUBLISH_USER` and `MEDIAMTX_PUBLISH_PASSWORD` Pi values are
preserved exactly, while missing Jetson values are added without rotating the
Pi account.

```bash
cd /home/ubuntu/william-james/infra
sudo ./provision-secrets.sh
sudo docker compose config --quiet
sudo docker compose up -d mediamtx
```

The Pi and Jetson accounts each have only `publish` permission and only for
canonical `live/{UUID}` paths. Neither has `read`, `playback`, `api`, `metrics`,
or `pprof` permission. App HLS reads use a separate anonymous MediaMTX identity
reachable only through host-loopback Nginx; Nginx remains responsible for
viewer authentication.

## Migration and rollback

Keep `MEDIAMTX_RTSP_ENCRYPTION=optional` while the Jetson's legacy SSH tunnel is
the rollback path. The tunnel URL must still contain the Jetson MediaMTX
credential; SSH encrypts the transport but does not bypass MediaMTX
authentication. Validate all of the following before tightening encryption:

1. No credential and a wrong credential cannot publish.
2. The Jetson credential cannot publish outside a canonical `live/{UUID}` path.
3. The Jetson credential cannot read the stream it published.
4. Direct RTSPS publish succeeds and the app plays the corresponding HLS stream.
5. Viewer close and idle timeout stop only the on-demand relay.

Then disable `wj-media-tunnel` on the Jetson, set:

```dotenv
MEDIAMTX_RTSP_ENCRYPTION=strict
```

and recreate MediaMTX. `strict` disables the plaintext `8554` rollback listener,
so do not make this change before direct RTSPS and app playback both pass.
