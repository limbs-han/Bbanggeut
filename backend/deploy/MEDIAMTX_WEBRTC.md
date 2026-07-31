# MediaMTX WebRTC 운영 확인

라이브 입력은 `Jetson -> RTSPS -> MediaMTX` 경로를 유지하고 앱에는
WHEP/WebRTC만 제공한다. 운영 MediaMTX는 HLS를 생성하지 않으며 앱도 HLS로
폴백하지 않는다.

## 네트워크

- `443/TCP`: Nginx가 `/webrtc/...` WHEP signaling을 MediaMTX `8889`로 전달
- `8189/UDP`: 앱과 MediaMTX 사이의 ICE 미디어
- `8889/TCP`: host loopback 전용이며 인터넷에 직접 공개하지 않음
- `8888/TCP`: 사용하지 않음

EC2 Security Group과 호스트 방화벽에서 `8189/UDP` 인바운드를 허용해야 한다.
`MEDIAMTX_WEBRTC_ADDITIONAL_HOSTS`에는 앱에서 접근 가능한 공인 도메인 또는
공인 IP를 설정한다.

## 배포 전 확인

1. `nginx -t`로 WHEP reverse proxy 설정을 검사한다.
2. `docker compose config`로 MediaMTX 포트와 환경 변수를 검사한다.
3. `mediamtx.yml`의 `hls: false`와 `webrtc: true`를 확인한다.
4. 기능 브랜치 CI 성공 후에만 배포 설정을 반영한다.
5. Wi-Fi와 LTE에서 각각 라이브를 열고 영상·오디오 RTP를 확인한다.
6. `8189/UDP` 차단 시험에서는 HLS 전환 없이 앱에 WebRTC 재시도 오류가
   표시되는지 확인한다.

현재 구성은 TURN relay를 포함하지 않는다. 일부 이동통신망이나 기업망에서
직접 UDP 연결 성공률이 낮으면 Coturn을 별도 기능으로 추가한다.
