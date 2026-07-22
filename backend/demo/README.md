# Full frontend demo

Run from the repository root:

```powershell
./backend/demo/start-demo.ps1
```

The script creates three overlapping two-minute clips from the supplied source
video, starts PostgreSQL/MinIO/MediaMTX and the Spring backend, uploads the clips,
seeds frontend fixtures, and publishes the source video as an endless RTSP/HLS
stream.

Demo credentials:

- Owner/admin: `admin@wj.local` / `WjDemo!2026`
- Existing member: `family@wj.local` / `WjFamily!2026`
- Pending member request: `request@wj.local` / `WjRequest!2026`
- Fixed registration code for a second camera: `WJDE-2026`

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
