# MediaMTX 단방향 WebRTC 운영 확인

라이브 입력은 기존 `Jetson -> RTSPS -> MediaMTX` 경로를 유지한다.
앱은 MediaMTX의 WHEP 출력으로 영상 트랙만 수신하고, 연결 실패 시 기존
HLS URL로 자동 전환한다.

## 외부 네트워크

- `443/TCP`: Nginx가 `/webrtc/...` WHEP signaling을 MediaMTX `8889`로 전달
- `8189/UDP`: 앱과 MediaMTX 사이의 ICE 미디어
- `8889/TCP`: host loopback에만 바인딩하며 외부에 직접 공개하지 않음

EC2 Security Group과 호스트 방화벽에서 `8189/UDP` 인바운드를 허용해야
한다. `MEDIAMTX_WEBRTC_ADDITIONAL_HOSTS`에는 앱에서 접근 가능한 공인
도메인 또는 공인 IP를 설정한다.

## 배포 전 확인

1. `nginx -t`로 WHEP reverse proxy 설정을 검사한다.
2. `docker compose config`로 MediaMTX 포트와 환경 변수를 검사한다.
3. 기능 브랜치 CI가 성공한 뒤에만 배포 설정을 반영한다.
4. Wi-Fi와 LTE에서 각각 라이브를 열고 MediaMTX 로그의 WebRTC session을
   확인한다.
5. `8189/UDP`를 차단한 시험에서 앱이 HLS로 자동 전환되는지 확인한다.

현재 구성은 TURN relay를 포함하지 않는다. 일부 이동통신망이나 기업망에서
직접 UDP 연결 성공률이 낮으면 Coturn을 별도 기능으로 추가한다.
