import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/core/models.dart';
import 'package:william_james_app/core/whip_publisher_controller.dart';

void main() {
  test('MediaMTX accepting the publisher answers recvonly audio', () {
    expect(
      WhipPublisherController.acceptsAudio(
        'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=recvonly\r\n',
      ),
      isTrue,
    );
    expect(
      WhipPublisherController.acceptsAudio(
        'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=sendrecv\r\n',
      ),
      isTrue,
    );
  });

  test('a rejected or inactive audio section is not a usable talkback', () {
    // 포트 0은 MediaMTX가 오디오 자체를 거절했다는 뜻이다.
    expect(
      WhipPublisherController.acceptsAudio(
        'v=0\r\nm=audio 0 UDP/TLS/RTP/SAVPF 0\r\n',
      ),
      isFalse,
    );
    expect(
      WhipPublisherController.acceptsAudio(
        'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=inactive\r\n',
      ),
      isFalse,
    );
    // sendonly는 서버가 보내겠다는 뜻이라 발화 경로로는 쓸 수 없다.
    expect(
      WhipPublisherController.acceptsAudio(
        'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=sendonly\r\n',
      ),
      isFalse,
    );
    expect(
      WhipPublisherController.acceptsAudio(
        'v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\n',
      ),
      isFalse,
    );
  });

  test('the WHIP session URL keeps the talk token from the offer URL', () {
    // MediaMTX의 Location 헤더에는 토큰이 없다. 토큰을 잃으면 Nginx가
    // DELETE를 401로 막고 발화 권한이 만료까지 남는다.
    final resolved = WhipPublisherController.copyAccessQuery(
      Uri.parse('https://media.example/webrtc/talkback/session/abc'),
      Uri.parse(
        'https://media.example/webrtc/talkback/s1/whip?token=talk-token',
      ),
    );

    expect(resolved.queryParameters['token'], 'talk-token');
    expect(resolved.path, '/webrtc/talkback/session/abc');
  });

  test('TalkbackSession reads the whip url and lease expiry', () {
    final session = TalkbackSession.fromJson(const {
      'sessionId': '11111111-1111-4111-8111-111111111111',
      'streamId': '22222222-2222-4222-8222-222222222222',
      'deviceId': '33333333-3333-4333-8333-333333333333',
      'whipUrl': 'https://media.example/webrtc/talkback/s1/whip?token=t',
      'heartbeatIntervalSeconds': 15,
      'expiresAt': '2026-08-01T12:00:30.000Z',
    });

    expect(
      session.whipUrl,
      'https://media.example/webrtc/talkback/s1/whip?token=t',
    );
    // parseDate는 저장소 공통 동작대로 로컬 시각으로 변환한다.
    expect(
      session.expiresAt?.toUtc(),
      DateTime.parse('2026-08-01T12:00:30.000Z'),
    );
  });
}
