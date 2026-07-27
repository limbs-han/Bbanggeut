# Full frontend demo

Run from the repository root:

```powershell
./backend/demo/start-demo.ps1
```

The script creates three overlapping two-minute clips from the supplied source
video, starts PostgreSQL/MinIO/MediaMTX and the Spring backend, uploads the clips,
seeds frontend fixtures, and publishes the source video as an endless RTSP/HLS
stream.

## Publish the Windows laptop webcam to production

For a real live-camera test, the PowerShell helper replaces the looping
`demo-live` publisher with the laptop webcam. It uses an SSH tunnel, so the
production RTSP port remains bound to loopback and is never exposed publicly.

```powershell
.\backend\demo\start-webcam-live.ps1
```

The default camera is `Camera Sensor OV02C10` at 1280x720/30fps. Override it
with `-CameraName`, `-VideoSize`, or `-FrameRate` when needed. Restore the
looping server video after the test with:

```powershell
.\backend\demo\stop-webcam-live.ps1
```

Demo credentials:

- Owner/admin: `admin@wj.local` / `WjDemo!2026`
- Existing editor: `family@wj.local` / `WjFamily!2026`
- Pending viewer invitation: `request@wj.local` / `WjRequest!2026`
- Fixed registration code for a second camera: `WJDE-2026`

Six additional accounts start without a device and therefore open the
device-registration screen. Claiming the paired code makes the account OWNER:

| Account | Password | Registration code |
| --- | --- | --- |
| `admin01@wj.local` | `WjAdmin01!2026` | `WJ01-2026` |
| `admin02@wj.local` | `WjAdmin02!2026` | `WJ02-2026` |
| `admin03@wj.local` | `WjAdmin03!2026` | `WJ03-2026` |
| `admin04@wj.local` | `WjAdmin04!2026` | `WJ04-2026` |
| `admin05@wj.local` | `WjAdmin05!2026` | `WJ05-2026` |
| `admin06@wj.local` | `WjAdmin06!2026` | `WJ06-2026` |

The admin and family accounts already have access to the seeded primary camera,
so Flutter opens the main shell instead of the device-registration screen. The
request account has no camera yet and opens its pending invitation flow. Use
`WJDE-2026` only when explicitly testing claim of the separate second camera.

Run Flutter against the real API, not the old frontend-only shortcut:

```powershell
cd frontend
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8080
```

Use `http://localhost:8080` for Flutter Web or a Windows desktop build. On a
physical phone, replace `10.0.2.2` with the development PC's LAN IP. The HLS URL
returned by the backend also needs to use an address reachable by that phone;
pass `-DemoLiveHlsUrl http://<PC-LAN-IP>:8888/demo-live/index.m3u8` when testing
physically. For Flutter Web/Windows, pass the same option with `localhost`.

Stop only the demo processes:

```powershell
./backend/demo/stop-demo.ps1
```

Add `-StopContainers` to stop PostgreSQL, MinIO and MediaMTX too. Re-running the
start script resets the fixed claim camera/code and the pending join request while
preserving unrelated local data.
